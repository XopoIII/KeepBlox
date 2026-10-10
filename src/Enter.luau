--!strict
--- The second half of a load: from the key just claimed to the live session the game holds.
---
--- A trade the key's last server did not finish is settled first (see Trade); otherwise a server that
--- died may have left newer play in MemoryStore, which is stored at once (see Recover). Then the data
--- is unpacked, migrated and filled from the template, and the session is made and listed.
---
--- Nothing here lets go of the key: a load that fails here, or throws, is undone by its caller (see
--- Open), which holds the claim.
const Apart = require("./Apart")
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
const Signal = require("./Signal")
const Snapshots = require("./Snapshots")
const Trade = require("./Trade")
const Types = require("./Types")
const Upkeep = require("./Upkeep")
const Validate = require("./Validate")

export type Failure = "timeout" | "newerSchema" | "migration" | "schema"

--> `message` is for `store.onError`, once the key has been given back.
export type Result = { ok: true, session: Session.Session } | { ok: false, reason: Failure, message: string? }

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

const Enter = {}

-- A stable spread of renewal times over the interval, from the key alone.
const function offset(key: string): number
	local hash = 0
	for index = 1, #key do
		hash = (hash * 31 + string.byte(key, index)) % 1000
	end
	return hash / 1000
end

--> Makes the session of `key`, which `taken` claimed for `context`, and lists it in the store. A
--> failure leaves the key claimed and nothing listed.
function Enter.session(
	state: State,
	context: Session.Context,
	key: string,
	taken: Lock.Taken,
	listener: Upkeep.Listener
): Result
	const services = context.services
	const clock = services.clock
	const plan = state.plan
	local record = taken.record
	-- A trade its last server did not finish is settled before anything else (see Trade); otherwise a
	-- server that died may have left newer play in MemoryStore (see Recover).
	const journal = Record.ours(record.MetaData).trade
	if journal == nil then
		local unstored
		record, unstored = Recover.run(context, key, taken.loadCount, record, taken.previous)
		if unstored then
			-- Kept as claimed: undoing this load tries that beat again, against the data as stored.
			taken.record = Record.copy(record)
		else
			-- That beat is seen to: undoing this load has nothing of it left to store (see LetGo).
			taken.previous = nil
		end
	else
		-- A profile in a trade has no snapshot (see Lease): nothing of its last owner is left to store.
		taken.previous = nil
	end
	record.Data = Codec.unpack(services.codec, record.Data)
	if journal then
		const settled = Trade.recover(context, state.name, record)
		if settled == nil then
			return { ok = false, reason = "timeout" }
		end
		record.Data = settled
	end
	-- The data as stored, before any migration: a profile that did not change is not written again.
	const stored = if journal then nil else Validate.check(record.Data, "Data", nil, Validate.slicer(clock))
	const migrated = Migrate.run(plan, record.Data, Migrate.stored(record))
	if not migrated.ok then
		-- Never hand out, or write back, data this server cannot make sense of.
		return { ok = false, reason = migrated.reason, message = migrated.message }
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
		owed = nil :: Lock.Previous?,
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
	return { ok = true, session = session }
end

return Enter
