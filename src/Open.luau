--!strict
--- Loading a key: from the claim to the live session the game holds.
---
--- A player who leaves and joins the same server again before the release finished (a quick rejoin,
--- or a teleport that failed) does not get "open": the load waits for that release (see Settle), then
--- claims the key afresh. A session that is still live is a second load of the same key, and gets "open".
---
--- A template store fills keys the stored data lacks with copies from the template, deeply, on every
--- load (a schema store does the same through its defaults). Existing values are never replaced.
---
--- The load runs in a thread the library owns (see Apart), so a caller the game cancels in the middle
--- leaves nothing half done: the load runs to its end, and a session it opens, which nobody is left
--- to hold, is released at once with all it read. A later load of the key waits for that, then claims
--- the key afresh.
const Apart = require("./Apart")
const Claim = require("./Claim")
const Codec = require("./Codec")
const Config = require("./Config")
const Import = require("./Import")
const Inbox = require("./Inbox")
const Lock = require("./Lock")
const Messages = require("./Messages")
const Migrate = require("./Migrate")
const Profile = require("./Profile")
const Record = require("./Record")
const Recover = require("./Recover")
const Serial = require("./Serial")
const Session = require("./Session")
const Settle = require("./Settle")
const Signal = require("./Signal")
const Snapshots = require("./Snapshots")
const Trade = require("./Trade")
const Types = require("./Types")
const Upkeep = require("./Upkeep")
const Validate = require("./Validate")

export type LoadOptions = {
	--> Polled while the load waits; true gives up (the player left).
	cancel: (() -> boolean)?,
	--> Take the key at once from whoever holds it, as ProfileStore's `Steal = true`. For recovering a
	--> key stuck on a dead server by hand; a normal load never needs it.
	steal: boolean?,
	--> Never ask a live owner to hand the key over (no player is kicked): fail with "inUse" instead.
	--> A dead owner is still taken over, once its lease has not moved for `death` seconds. For
	--> support tools and offline edits (`store:edit`).
	quiet: boolean?,
}

export type Failure = Claim.Failure | "open" | "newerSchema" | "migration" | "schema"

export type LoadResult<T = any> = { ok: true, profile: Profile.Profile<T> } | { ok: false, reason: Failure }

--> What a load needs from its store.
export type State = {
	name: string,
	template: { [any]: any },
	--> The template as a new profile is stored: at the plan's `write` version (see Migrate).
	storedTemplate: { [any]: any },
	--> Fill missing keys from the template on load (a template store; off for the ProfileStore shim).
	reconcile: boolean,
	plan: Migrate.Plan,
	config: Config.Config,
	--> The store's context. Its services can change once (Studio without access switches to memory).
	base: Session.Context,
	sessions: { [string]: Session.Session },
	--> The keys being loaded, each with the thread that asked for it.
	opening: { [string]: thread },
	onError: Signal.Signal<string, string>,
	closing: () -> boolean,
	--> Runs before the first load: the Studio access check.
	prepare: () -> (),
	--> Where missing keys take their data from, when moving from another library.
	importer: Import.Importer?,
	--> This server's MemoryStore beat landed last time (see Lease).
	beating: () -> boolean,
}

const Open = {}

-- A stable spread of renewal times over the interval, from the key alone.
const function offset(key: string): number
	local hash = 0
	for index = 1, #key do
		hash = (hash * 31 + string.byte(key, index)) % 1000
	end
	return hash / 1000
end

const function stopListening(listener: Upkeep.Listener)
	listener.done = true
	if listener.connection then
		listener.connection:Disconnect()
	end
end

-- The load of a key marked as opening, in a thread of its own. `asker` is the thread that waits for
-- it: once the game has cancelled that thread, nobody is left to hold the profile.
const function open(state: State, key: string, options: LoadOptions?, deadline: number, asker: thread): LoadResult
	const cancel = options and options.cancel
	state.prepare()
	const services = state.base.services
	const clock = services.clock
	const plan = state.plan
	const context = table.clone(state.base)
	context.identity = { placeId = services.placeId, jobId = services.jobId, guid = services.guid() }
	context.deadline = deadline
	const mode: Lock.Mode = {
		force = options ~= nil and options.steal == true,
		quiet = options ~= nil and options.quiet == true,
		version = plan.write,
	}
	local template = state.storedTemplate
	const importer = state.importer
	if importer then
		const prepared = Import.prepare(context, key, importer, cancel)
		if not prepared.ok then
			state.opening[key] = nil
			return { ok = false, reason = prepared.reason }
		end
		mode.imported = importer.name
		-- An old value at this very key is converted inside the claim; one from elsewhere was read here.
		mode.adopt = if importer.fetch == nil then importer.read else nil
		if prepared.data ~= nil then
			template = prepared.data
			mode.fromImport = true
			mode.userIds = prepared.userIds
		end
	end
	const listener: Upkeep.Listener = { session = nil, connection = nil, done = false }
	Upkeep.listen(services, context.identity.guid, listener)
	mode.memory = state.beating()
	const claim = Claim.open(context, state.name, key, template, cancel, mode)
	-- The key stays `opening` until its session is listed: recovering a dead owner's play, settling a
	-- trade and checking the data all yield, and a second load of the key meanwhile would claim it again.
	if not claim.ok then
		state.opening[key] = nil
		stopListening(listener)
		return { ok = false, reason = claim.reason }
	end
	const taken = claim.taken
	local record = taken.record
	-- A trade its last server did not finish is settled before anything else (see Trade); otherwise a
	-- server that died may have left newer play in MemoryStore (see Recover).
	const journal = Record.ours(record.MetaData).trade
	if journal == nil then
		record = Recover.run(context, key, taken.loadCount, record, taken.previous)
	end
	record.Data = Codec.unpack(services.codec, record.Data)
	if journal then
		const settled = Trade.recover(context, state.name, record)
		if settled == nil then
			Claim.giveBack(context, key, taken.loadCount)
			state.opening[key] = nil
			stopListening(listener)
			return { ok = false, reason = "timeout" }
		end
		record.Data = settled
	end
	-- The data as stored, before any migration: a profile that did not change is not written again.
	const stored = if journal then nil else Validate.check(record.Data, "Data", nil, Validate.slicer(clock))
	const migrated = Migrate.run(plan, record.Data, Migrate.stored(record))
	if not migrated.ok then
		-- Never hand out, or write back, data this server cannot make sense of.
		Claim.giveBack(context, key, taken.loadCount)
		state.opening[key] = nil
		stopListening(listener)
		state.onError:fire(key, migrated.message)
		return { ok = false, reason = migrated.reason }
	end
	record.Data = migrated.data
	if state.reconcile and plan.schema == nil then
		Record.reconcile(record.Data, state.template)
	end
	local session: Session.Session
	const profile = Profile.new(key, taken.loadCount, taken.lastSavedAt, record, clock.spawn, {
		isActive = function(): boolean
			return session.active and not session.releasing
		end,
		save = function(): boolean
			return Session.save(context, session)
		end,
		release = function()
			-- In a thread the library owns: a caller cancelled between two tries of the final write
			-- must not stop the retries (see Apart).
			Apart.run(clock, function(problem: any)
				state.onError:fire(key, `a release failed after its caller was cancelled: {problem}`)
			end, Session.release, context, session, "released")
		end,
		handle = function(handler: Inbox.Handler)
			session.inbox:handle(handler)
		end,
	})
	-- Migrated data is written at the first renewal, with its new schema version.
	const encoded = if migrated.changed then nil else stored
	session = {
		key = key,
		loadCount = taken.loadCount,
		profile = profile,
		context = context,
		active = true,
		releasing = false,
		storedText = if encoded then encoded.text else "",
		storedSize = if encoded then encoded.size else 0,
		lastDataWrite = clock.now(),
		nextRenew = clock.now() + state.config.renew * (1 + offset(key)),
		serial = Serial.new(clock, function(problem: any)
			state.onError:fire(key, `a write failed after its caller was cancelled: {problem}`)
		end),
		lastProblem = nil :: string?,
		inbox = Inbox.new(clock, function()
			session.saveSoon = true
		end, function(message: string)
			state.onError:fire(key, message)
		end),
		saveSoon = false,
		receipts = Record.receipts(record.MetaData),
		storedReceipts = {},
		listener = listener,
		pending = nil :: Session.Pending?,
		clearJournal = journal ~= nil,
		snapSeq = 0,
		snapText = "",
		snapshotted = false,
		trading = false,
		good = nil :: Types.Good?,
		base = nil :: Types.Base?,
	}
	if encoded then
		Snapshots.stored(context, session, encoded, record.Data)
	end
	listener.session = session
	session.inbox:receive(Messages.list(record))
	for _, id in session.receipts do
		session.storedReceipts[id] = true
	end
	state.sessions[key] = session
	context.deadline = nil -- the session lives on in this context; the load's deadline does not
	if coroutine.status(asker) == "dead" then
		-- Nobody is left to play on this profile or to release it. The key stays `opening` meanwhile,
		-- so a later load of it and the shutdown both wait for the release.
		Session.release(context, session, "released")
		state.opening[key] = nil
		return { ok = false, reason = "cancelled" }
	end
	state.opening[key] = nil
	return { ok = true, profile = profile }
end

function Open.load(state: State, key: string, options: LoadOptions?): LoadResult
	assert(type(key) == "string" and #key > 0 and #key <= 50, "KeepBlox: a key is 1-50 characters")
	const clock = state.base.services.clock
	-- One deadline for the whole load: waiting for a release here, the import, the claim and a trade's
	-- settling all count against it, so the load answers within `loadTimeout`.
	const deadline = clock.now() + state.config.loadTimeout
	const waited = Settle.wait(state, clock, key, options and options.cancel, deadline)
	if waited then
		return { ok = false, reason = waited }
	end
	if state.sessions[key] or state.opening[key] then
		return { ok = false, reason = "open" }
	end
	const asker = coroutine.running()
	state.opening[key] = asker
	return Apart.run(clock, function(problem: any)
		state.onError:fire(key, `a load failed after its caller was cancelled: {problem}`)
	end, function(): LoadResult
		const ok, result = pcall(open, state, key, options, deadline, asker)
		if not ok then
			-- A load that throws is over: its key must not stay marked as opening.
			state.opening[key] = nil
			error(result, 0)
		end
		return result
	end)
end

return Open
