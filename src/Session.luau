--!strict
--- One open session: its writes (renewals, saves, the release), one at a time.
---
--- Every write goes through `Lock.save`, so it lands only while this session still owns the key. A
--- write that finds the key owned elsewhere ends the session at once: it is marked lost, its data
--- is frozen, and the game is told. That is how a lost session stops trades on a stale copy
--- (guarantee 6).
---
--- The data is checked before every write. Data that cannot be stored is not written; the lease is
--- still renewed and the last good save stays. So one bad value never blocks the session, its
--- hand-over or its release (the "poison" scenario), and the error names the value's path.
const Call = require("./Call")
const Codec = require("./Codec")
const Lock = require("./Lock")
const Migrate = require("./Migrate")
const Profile = require("./Profile")
const Record = require("./Record")
const Repair = require("./Repair")
const Schema = require("./Schema")
const Snapshots = require("./Snapshots")
const Types = require("./Types")
const Validate = require("./Validate")

export type Context = Types.Context
export type Session = Types.Session
export type Pending = Types.Pending

const Session = {}

--> Ends `session` for `reason`: it stops writing, its data is frozen, and the game is told.
function Session.finish(context: Context, session: Session, reason: Profile.EndReason)
	if not session.active then
		return
	end
	session.active = false
	session.inbox:close()
	session.listener.done = true
	if session.listener.connection then
		session.listener.connection:Disconnect()
		session.listener.connection = nil
	end
	Profile.freeze(session.profile.Data)
	context.forget(session)
	session.profile.onEnded:fire(reason)
end

-- One write, inside the session's serial lane. Returns whether it was stored.
const function write(
	context: Context,
	session: Session,
	release: boolean,
	reason: Profile.EndReason,
	automatic: boolean
): boolean
	if not session.active then
		return false
	end
	const clock = context.services.clock
	const profile = session.profile
	if not release then
		profile.onSaving:fire(false, nil)
	end
	-- Copy at once (fast), then check the copy in slices, so a large profile never stalls a frame.
	local snapshot = Record.copy(profile.Data)
	-- Taken at the same moment as the snapshot: the effects of these messages are in it.
	local consumed = session.inbox:processed()
	local receipts = table.clone(session.receipts)
	local newReceipt = false
	for _, id in receipts do
		if not session.storedReceipts[id] then
			newReceipt = true
		end
	end
	-- What is stored: the snapshot, or in a release that can be rolled back, the snapshot turned back to
	-- the version it stores (see Migrate), checked against the schema first.
	const plan = context.plan
	const schema = plan.schema
	local storable, turned = snapshot, nil :: string?
	if plan.write < plan.version then
		turned = if schema then Schema.check(schema, snapshot) else nil
		if turned == nil then
			storable, turned = Migrate.store(plan, Record.copy(snapshot))
		end
	end
	-- A compressing store checks the size of what it stores (Codec), not of the data in memory.
	local encoded, problem =
		Validate.check(storable, "Data", if context.compress then math.huge else nil, Validate.slicer(clock))
	local repairing = false
	if turned then
		encoded, problem = nil, turned
	elseif encoded == nil then
		-- One bad value must not cost the play around it: a repaired copy is stored instead (see Repair).
		const repaired = Record.copy(storable)
		const fixes = Repair.run(repaired, "Data")
		const again = if #fixes > 0
			then Validate.check(repaired, "Data", if context.compress then math.huge else nil, Validate.slicer(clock))
			else nil
		if again then
			const note = `stored with a repair: {fixes[1]}{if #fixes > 1 then ` (and {#fixes - 1} more)` else ""}`
			if note ~= session.lastProblem then
				session.lastProblem = note
				context.report(session.key, note)
			end
			if storable == snapshot then
				snapshot = repaired
			end
			storable, encoded, problem, repairing = repaired, again, nil, true
		end
	end
	if encoded and schema and plan.write == plan.version and encoded.text ~= session.storedText then
		-- Only changed data is checked against the schema; unchanged data passed already.
		const broken = Schema.check(schema, snapshot)
		if broken then
			encoded, problem = nil, broken
		end
	end
	local data: any = nil
	if encoded == nil then
		if problem ~= session.lastProblem then
			session.lastProblem = problem
			context.report(session.key, `not saved: {problem}`)
		end
		-- The last snapshot that could be stored is newer than the store's copy: that is stored instead,
		-- with the messages and receipts that were in it (see Lease).
		const good = session.good
		if good and good.text ~= session.storedText then
			snapshot, consumed, receipts, data = good.play, good.consumed, good.receipts, good.data
			encoded = { text = good.text, size = good.size }
		end
	elseif encoded.text ~= session.storedText or next(consumed) ~= nil or newReceipt then
		if not repairing then
			session.lastProblem = nil
		end
		-- A large profile writes less often, to stay inside the key's write throughput. Processed
		-- messages do not wait: their removal must be written with their effect.
		const spacing = encoded.size * 60 / context.config.writeBytesPerMinute
		const urgent = next(consumed) ~= nil or newReceipt or session.clearJournal
		if not automatic or urgent or clock.now() - session.lastDataWrite >= spacing then
			data, problem = Codec.pack(context.services.codec, context.compress, storable, encoded.size)
			if problem and problem ~= session.lastProblem then
				session.lastProblem = problem
				context.report(session.key, `not saved: {problem}`)
			end
		end
	end
	const payload: Lock.Payload = {
		data = data,
		userIds = table.clone(profile.UserIds),
		robloxMetaData = Record.copy(profile.RobloxMetaData),
		release = release,
		consumed = if data ~= nil then consumed else nil,
		receipts = if data ~= nil then receipts else nil,
		schemaVersion = if data ~= nil then plan.write else nil,
		memory = context.beating ~= nil and context.beating(),
		snap = session.snapSeq,
		-- A settled trade's journal goes only with data that matches memory (see Trade).
		journal = if session.clearJournal and (data ~= nil or (encoded and encoded.text == session.storedText))
			then false
			else nil,
	}
	local outcome: Lock.Save? = nil
	const ok, err = Call.run(
		clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		session.key,
		function(value: any): any
			const record, result = Lock.save(value, context.identity, session.loadCount, payload, clock.time())
			outcome = result
			return record
		end
	)
	if not ok then
		context.report(session.key, `save failed: {err}`)
		return false
	end
	const result = outcome :: Lock.Save
	if result.kind == "lost" then
		Session.finish(context, session, "lost")
		return false
	end
	if payload.journal == false then
		session.clearJournal = false
	end
	if data ~= nil and encoded then
		Snapshots.stored(context, session, encoded, data)
		session.lastDataWrite = clock.now()
	end
	if data ~= nil then
		session.inbox:removed(consumed)
		for _, id in receipts do
			session.storedReceipts[id] = true
		end
	end
	session.inbox:receive(result.messages)
	-- What the store holds now, uncompressed: the snapshot just written, or what already was.
	const saved = if data ~= nil
		then snapshot
		elseif Codec.packed(result.record.Data) then profile.LastSavedData
		else result.record.Data
	profile.LastSavedData = Record.copy(saved)
	profile.onSaved:fire(Record.copy(saved))
	if context.stored then
		context.stored(session.key, saved, release)
	end
	if release then
		Session.finish(context, session, reason)
	elseif result.handOver then
		-- Another server asked for the key: hand it over now, with a final save.
		clock.spawn(Session.release, context, session, "handedOver")
	end
	return true
end

--> Saves now (renewing the lease). Returns whether the save was stored. An `automatic` save (a
--> renewal) may leave changed data for later, to keep a large profile inside the key's write throughput.
function Session.save(context: Context, session: Session, automatic: boolean?): boolean
	if not session.active then
		return false
	end
	if automatic == true then
		return session.serial:run(write, context, session, false, "released", true)
	end
	const joined = session.pending
	if joined then
		table.insert(joined.waiters, coroutine.running())
		return coroutine.yield()
	end
	const pending: Pending = { done = false, stored = false, waiters = {} }
	session.pending = pending
	const ok, stored = pcall(session.serial.run, session.serial, function(): boolean
		-- The snapshot is taken from here on: a later call must queue a save of its own.
		if session.pending == pending then
			session.pending = nil
		end
		return write(context, session, false, "released", false)
	end)
	if session.pending == pending then
		session.pending = nil
	end
	pending.done = true
	pending.stored = ok and stored == true
	for _, waiter in pending.waiters do
		context.services.clock.spawn(waiter, pending.stored)
	end
	if not ok then
		error(stored, 0)
	end
	return pending.stored
end

--> Ends the session with a final save, retrying until it is stored, the key turns out to be owned
--> elsewhere, or shutdown runs out of time.
function Session.release(context: Context, session: Session, reason: Profile.EndReason)
	const clock = context.services.clock
	const config = context.config
	if session.active and not session.releasing then
		-- From here the game sees the profile as ended: it gets one last chance to write, then the
		-- data freezes, so the final save holds every change the game made.
		session.releasing = true
		session.profile.onSaving:fire(true, reason)
		Profile.freeze(session.profile.Data)
	end
	local delay = config.backoffMin
	while session.active do
		if session.serial:run(write, context, session, true, reason, false) or not session.active then
			return
		end
		clock.wait(delay)
		delay = math.min(delay * 2, config.backoffMax)
	end
end

return Session
