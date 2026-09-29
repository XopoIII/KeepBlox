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
const Config = require("./Config")
const Inbox = require("./Inbox")
const Lock = require("./Lock")
const Migrate = require("./Migrate")
const Profile = require("./Profile")
const Record = require("./Record")
const Schema = require("./Schema")
const Serial = require("./Serial")
const Services = require("./Services")
const Validate = require("./Validate")

-- The most CPU time one write spends before it lets a frame pass.
const SLICE_SECONDS = 0.002

export type Context = {
	services: Services.Services,
	config: Config.Config,
	dataStore: Services.DataStore,
	identity: Record.Identity,
	--> Reports a problem with a key; the store turns it into its `onError` signal.
	report: (key: string, message: string) -> (),
	--> True once the server began shutting down.
	closing: () -> boolean,
	--> The schema and migrations the data follows.
	plan: Migrate.Plan,
	--> Called once when a session ends, so the store can forget it.
	forget: (session: Session) -> (),
	--> Called after each save stored the data (`final` on the release): the leaderboards' mirror.
	stored: ((key: string, data: any, final: boolean) -> ())?,
}

export type Session = {
	key: string,
	loadCount: number,
	profile: Profile.Profile,
	--> The context this session writes with: the store's, with this session's own identity.
	context: Context,
	active: boolean,
	--> True from the moment a release begins: the data is frozen then, so the final save holds every
	--> change the game made.
	releasing: boolean,
	--> The canonical text of the data as last stored.
	storedText: string,
	storedSize: number,
	lastDataWrite: number,
	nextRenew: number,
	serial: Serial.Serial,
	--> The last validation problem reported, so it is not reported on every renewal.
	lastProblem: string?,
	--> The incoming messages and their handlers.
	inbox: Inbox.Inbox,
	--> Save at the next tick, not at the next renewal: a message was processed, or someone sent one.
	saveSoon: boolean,
	--> Purchase receipt ids granted into the data, the ones not yet stored included (see Receipts).
	receipts: { string },
	--> The receipt ids the store is known to hold.
	storedReceipts: { [string]: boolean },
	--> The hand-over subscription, set up before the claim; `done` once the session ended.
	listener: { session: Session?, connection: Services.Connection?, done: boolean },
	--> A manual save waiting in the lane that has not taken its snapshot yet. Later calls join it:
	--> its snapshot will hold their changes, so a game calling `save` in a loop makes one write, not
	--> a queue of them.
	pending: Pending?,
	--> The record holds a settled trade's journal: the next write that stores this data clears it.
	clearJournal: boolean,
}

export type Pending = { done: boolean, stored: boolean, waiters: { thread } }

const Session = {}

--> A `pause` for `Validate.check` that lets a frame pass after every `SLICE_SECONDS` of CPU time.
function Session.slicer(clock: Services.Clock): () -> ()
	local started = os.clock()
	return function()
		if os.clock() - started >= SLICE_SECONDS then
			clock.wait()
			started = os.clock()
		end
	end
end

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
	const snapshot = Record.copy(profile.Data)
	-- Taken at the same moment as the snapshot: the effects of these messages are in it.
	const consumed = session.inbox:processed()
	const receipts = table.clone(session.receipts)
	local newReceipt = false
	for _, id in receipts do
		if not session.storedReceipts[id] then
			newReceipt = true
		end
	end
	local encoded, problem = Validate.check(snapshot, "Data", nil, Session.slicer(clock))
	const schema = context.plan.schema
	if encoded and schema and encoded.text ~= session.storedText then
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
	elseif encoded.text ~= session.storedText or next(consumed) ~= nil or newReceipt then
		session.lastProblem = nil
		-- A large profile writes less often, to stay inside the key's write throughput. Processed
		-- messages do not wait: their removal must be written with their effect.
		const spacing = encoded.size * 60 / context.config.writeBytesPerMinute
		const urgent = next(consumed) ~= nil or newReceipt or session.clearJournal
		if not automatic or urgent or clock.now() - session.lastDataWrite >= spacing then
			data = snapshot
		end
	end
	const payload: Lock.Payload = {
		data = data,
		userIds = table.clone(profile.UserIds),
		robloxMetaData = Record.copy(profile.RobloxMetaData),
		release = release,
		consumed = if data ~= nil then consumed else nil,
		receipts = if data ~= nil then receipts else nil,
		schemaVersion = if data ~= nil then context.plan.version else nil,
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
		session.storedText = encoded.text
		session.storedSize = encoded.size
		session.lastDataWrite = clock.now()
	end
	if data ~= nil then
		session.inbox:removed(consumed)
		for _, id in receipts do
			session.storedReceipts[id] = true
		end
	end
	session.inbox:receive(result.messages)
	profile.LastSavedData = Record.copy(result.record.Data)
	profile.onSaved:fire(Record.copy(result.record.Data))
	if context.stored then
		context.stored(session.key, result.record.Data, release)
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
