--!strict
--- Loading a key: from the claim to the live session the game holds.
---
--- A player who leaves and joins the same server again before the release finished (a quick rejoin,
--- or a teleport that failed) does not get "open": the load waits for that release, then claims the key
--- afresh. A session that is still live is a second load of the same key, and gets "open".
---
--- A template store fills keys the stored data lacks with copies from the template, deeply, on every
--- load (a schema store does the same through its defaults). Existing values are never replaced.
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
const Serial = require("./Serial")
const Session = require("./Session")
const Signal = require("./Signal")
const Trade = require("./Trade")
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

export type LoadResult = { ok: true, profile: Profile.Profile } | { ok: false, reason: Failure }

--> What a load needs from its store.
export type State = {
	name: string,
	template: { [any]: any },
	--> Fill missing keys from the template on load (a template store; off for the ProfileStore shim).
	reconcile: boolean,
	plan: Migrate.Plan,
	config: Config.Config,
	--> The store's context. Its services can change once (Studio without access switches to memory).
	base: Session.Context,
	sessions: { [string]: Session.Session },
	opening: { [string]: boolean },
	onError: Signal.Signal<string, string>,
	closing: () -> boolean,
	--> Runs before the first load: the Studio access check.
	prepare: () -> (),
	--> Where missing keys take their data from, when moving from another library.
	importer: Import.Importer?,
}

-- How often a load waiting on this server's own release looks again.
const RELEASE_POLL = 0.1

const Open = {}

-- A stable spread of renewal times over the interval, from the key alone.
const function offset(key: string): number
	local hash = 0
	for index = 1, #key do
		hash = (hash * 31 + string.byte(key, index)) % 1000
	end
	return hash / 1000
end

-- Waits while this server is still releasing `key`. Returns a failure when the wait must stop.
const function awaitRelease(state: State, key: string, cancel: (() -> boolean)?): Claim.Failure?
	const clock = state.base.services.clock
	const started = clock.now()
	while true do
		const existing = state.sessions[key]
		if existing == nil or not existing.releasing then
			return nil
		elseif state.closing() then
			return "closing"
		elseif cancel and cancel() then
			return "cancelled"
		elseif clock.now() - started > state.config.loadTimeout then
			return "timeout"
		end
		clock.wait(RELEASE_POLL)
	end
end

const function stopListening(listener: Upkeep.Listener)
	listener.done = true
	if listener.connection then
		listener.connection:Disconnect()
	end
end

function Open.load(state: State, key: string, options: LoadOptions?): LoadResult
	assert(type(key) == "string" and #key > 0 and #key <= 50, "KeepBlox: a key is 1-50 characters")
	const cancel = options and options.cancel
	const waited = awaitRelease(state, key, cancel)
	if waited then
		return { ok = false, reason = waited }
	end
	if state.sessions[key] or state.opening[key] then
		return { ok = false, reason = "open" }
	end
	state.opening[key] = true
	state.prepare()
	const services = state.base.services
	const clock = services.clock
	const plan = state.plan
	const context = table.clone(state.base)
	context.identity = { placeId = services.placeId, jobId = services.jobId, guid = services.guid() }
	const mode: Lock.Mode = {
		force = options ~= nil and options.steal == true,
		quiet = options ~= nil and options.quiet == true,
		version = plan.version,
	}
	local template = state.template
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
	const claim = Claim.open(context, state.name, key, template, cancel, mode)
	state.opening[key] = nil
	if not claim.ok then
		stopListening(listener)
		return { ok = false, reason = claim.reason }
	end
	const record = claim.record
	record.Data = Codec.unpack(services.codec, record.Data)
	-- A trade its last server did not finish is settled before anything else (see Trade).
	const journal = Record.ours(record.MetaData).trade
	if journal then
		const settled = Trade.recover(context, state.name, record)
		if settled == nil then
			Claim.giveBack(context, key, claim.loadCount)
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
		Claim.giveBack(context, key, claim.loadCount)
		stopListening(listener)
		state.onError:fire(key, migrated.message)
		return { ok = false, reason = migrated.reason }
	end
	record.Data = migrated.data
	if state.reconcile and plan.schema == nil then
		Record.reconcile(record.Data, state.template)
	end
	local session: Session.Session
	const profile = Profile.new(key, claim.loadCount, record, clock.spawn, {
		isActive = function(): boolean
			return session.active and not session.releasing
		end,
		save = function(): boolean
			return Session.save(context, session)
		end,
		release = function()
			Session.release(context, session, "released")
		end,
		handle = function(handler: Inbox.Handler)
			session.inbox:handle(handler)
		end,
	})
	-- Migrated data is written at the first renewal, with its new schema version.
	const encoded = if migrated.changed then nil else stored
	session = {
		key = key,
		loadCount = claim.loadCount,
		profile = profile,
		context = context,
		active = true,
		releasing = false,
		storedText = if encoded then encoded.text else "",
		storedSize = if encoded then encoded.size else 0,
		lastDataWrite = clock.now(),
		nextRenew = clock.now() + state.config.renew * (0.5 + offset(key) / 2),
		serial = Serial.new(clock),
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
	}
	listener.session = session
	session.inbox:receive(Messages.list(record))
	for _, id in session.receipts do
		session.storedReceipts[id] = true
	end
	state.sessions[key] = session
	return { ok = true, profile = profile }
end

return Open
