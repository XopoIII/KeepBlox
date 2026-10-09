--!strict
--- A store: the profiles of one data store, and the loop that keeps their leases alive.
---
---     const store = KeepBlox.store("Profiles", { template = { coins = 0 } })
---     const result = store:load(`u_{player.UserId}`, { cancel = function() return not player.Parent end })
---     if not result.ok then player:Kick(`Data failed to load ({result.reason})`) return end
---     const profile = result.profile
---
--- Every open session is written every `renew` seconds, one profile at a time and spread over the
--- interval. The write renews the lease and saves the data if it changed. The loop waits when the
--- server's data store budget is spent, so loads and releases are not starved. On shutdown every
--- session is released in parallel within the deadline.
const Boards = require("./Boards")
const Codec = require("./Codec")
const Config = require("./Config")
const Edit = require("./Edit")
const Import = require("./Import")
const Migrate = require("./Migrate")
const Open = require("./Open")
const Profile = require("./Profile")
const Record = require("./Record")
const Schema = require("./Schema")
const Receipts = require("./Receipts")
const Send = require("./Send")
const Services = require("./Services")
const Session = require("./Session")
const Signal = require("./Signal")
const Studio = require("./Studio")
const Trade = require("./Trade")
const Upkeep = require("./Upkeep")
const Validate = require("./Validate")
const Versions = require("./Versions")

export type Options = {
	--> The data a new profile starts with. Give this or `schema`, not both.
	template: { [any]: any }?,
	--> The shape of the data (see Schema). New profiles start from its defaults.
	schema: Schema.Node?,
	--> The schema version the data is at now; default: the highest migration.
	version: number?,
	--> Migrations `[n]`, each taking the data from version n - 1 to n (see Migrate): a function, or
	--> `{ up, down }`.
	migrations: { read [number]: Migrate.Migration }?,
	--> The version data is stored at; default: `version`. Below it, the release can be rolled back: the
	--> data is stored turned down to this version, which the release before reads (see Migrate).
	writeVersion: number?,
	--> The engine services; the real ones by default. Tests pass fakes.
	services: Services.Services?,
	--> Overrides for `Config.DEFAULT`.
	config: Config.Overrides?,
	--> Keep profiles in memory, never in a live data store: `true`, or the name of a scratch set. In
	--> Studio without API access, or in a place never published, this happens on its own (see Studio).
	mock: (boolean | string)?,
	--> Fill keys the stored data lacks from the template, deeply, on every load. Default true.
	reconcile: boolean?,
	--> What Studio play tests do with data (live servers ignore it):
	--> - "live" (default): the real store when API access is on, memory when it is off;
	--> - "memory": always memory, nothing live is read or written;
	--> - "copy": each profile starts as a copy of its live data (read once, never written), then lives in
	-->   memory. For testing against real profiles without touching them.
	studio: ("live" | "memory" | "copy")?,
	--> Where a key's data comes from on its first load, when moving from another library (see Import
	--> and `KeepBlox.importers`).
	import: Import.Importer?,
	--> Leaderboards: a number read from each profile's data, mirrored to an ordered data store and read
	--> back with `store:leaderboard` (see Boards).
	leaderboards: { [string]: Boards.Board }?,
	leaderboardOptions: Boards.Options?,
	--> Store profiles over `above` bytes compressed (see Codec). Off by default: ProfileStore cannot
	--> read a compressed profile.
	compress: Codec.Options?,
}

export type LoadOptions = Open.LoadOptions
export type LoadResult<T = any> = Open.LoadResult<T>
export type LoadFailure = Open.Failure

--> `T` is the shape of the profiles' data: `Store` alone is a store of `any`.
export type Store<T = any> = {
	name: string,
	--> Fires `(key, message)` for every problem worth logging: failed calls, refused data, quarantine.
	onError: Signal.Signal<string, string>,
	load: (self: Store<T>, key: string, options: LoadOptions?) -> LoadResult<T>,
	--> The open profiles, by key.
	profiles: (self: Store<T>) -> { [string]: Profile.Profile<T> },
	--> Queues an offline message for `key`, open or not (see Send).
	message: (self: Store<T>, key: string, message: { [any]: any }) -> Send.Result,
	--> Past versions of a key, newest last unless asked otherwise (see Versions).
	versions: (self: Store<T>, key: string, query: Versions.Query?) -> { Versions.Version },
	--> The data a key held at a version, or nil.
	readVersion: (self: Store<T>, key: string, version: string) -> any,
	--> Makes a version's data current. Refuses while any server holds the key.
	restore: (self: Store<T>, key: string, version: string) -> Versions.Restored,
	--> A ProcessReceipt callback for this store, answering with a decision's name (see Receipts).
	receipts: (self: Store<T>, options: Receipts.Options) -> (receipt: Receipts.Receipt) -> Receipts.Decision,
	--> Edits a key, open here or nobody's, without kicking anyone (see Edit). "inUse" when a live server
	--> holds it: send a message instead.
	edit: (self: Store<T>, key: string, edit: (data: T) -> (), options: Edit.Options?) -> Edit.Result,
	--> Releases every open profile in parallel, as a server shutdown does, and refuses new loads.
	--> Yields until done or `shutdownDeadline` passes. For tests, and for closing a store early.
	close: (self: Store<T>) -> (),
	--> One change to two profiles open on this server, landing in both or neither (see Trade).
	trade: (self: Store<T>, keyA: string, keyB: string, change: (dataA: T, dataB: T) -> ()) -> Trade.Result,
	--> The top of a leaderboard, `{key, value}` entries, highest first unless asked otherwise.
	leaderboard: (self: Store<T>, name: string, query: Boards.Query?) -> { Boards.Entry },
}

const Store = {}

function Store.new(name: string, options: Options): Store
	assert(type(name) == "string" and #name > 0, "KeepBlox: a store needs a name")
	assert(type(options) == "table", "KeepBlox: a store needs options")
	assert(
		(options.template == nil) ~= (options.schema == nil),
		"KeepBlox: a store needs a template or a schema, and not both"
	)
	const template = if options.schema then Schema.default(options.schema) else Record.copy(options.template)
	assert(
		type(template) == "table" and Validate.check(template, "template"),
		"KeepBlox: the template must be storable"
	)
	const plan = Migrate.plan(options.schema, options.version, options.migrations, options.writeVersion)
	const storedTemplate = Migrate.template(plan, template, Record.copy)
	const config = Config.resolve(options.config)
	const studio = options.studio or "live"
	assert(
		studio == "live" or studio == "memory" or studio == "copy",
		`KeepBlox: studio is "live", "memory" or "copy", not "{studio}"`
	)
	const origin = options.services or require("./RobloxServices").build()
	const onError: Signal.Signal<string, string> = Signal.new(origin.clock.spawn)
	const function report(key: string, message: string)
		onError:fire(key, message)
	end
	-- Studio may put the store in memory: at once (an unpublished place), or after the read its first
	-- load makes (no API access). Either is reported on that first load, once someone listens.
	const chosen = Studio.choose(origin, name, options.mock, studio, report)
	const services = chosen.services
	const sessions: { [string]: Session.Session } = {}
	const opening: { [string]: thread } = {}
	local closing = false

	const base: Session.Context = {
		storeName = name,
		services = services,
		config = config,
		dataStore = chosen.dataStore,
		identity = { placeId = services.placeId, jobId = services.jobId, guid = "" },
		plan = plan,
		report = report,
		closing = function(): boolean
			return closing
		end,
		forget = function(session: Session.Session)
			if sessions[session.key] == session then
				sessions[session.key] = nil
			end
		end,
	}
	if options.compress then
		assert(services.codec, "KeepBlox: these services cannot compress")
		assert(
			type(options.compress.above) == "number" and options.compress.above > 0,
			"KeepBlox: compress needs `above`, a positive number of bytes"
		)
		base.compress = options.compress
	end
	const boards = if options.leaderboards
		then Boards.new(function(): Services.Services
			return base.services
		end, name, options.leaderboards, options.leaderboardOptions, base.report, config.callTimeout)
		else nil
	if boards then
		base.stored = function(key: string, data: any, final: boolean)
			boards:stored(key, data, final)
		end
	end

	const internals: Upkeep.Internals = {
		context = function(): Session.Context
			return base
		end,
		sessions = sessions,
		opening = opening,
		closing = function(): boolean
			return closing
		end,
	}
	const beating = { ok = false, sentAt = -math.huge }
	base.beating = function(): boolean
		return beating.ok
	end
	const beatOnce, checkBeat = Upkeep.beat(internals, beating)
	Upkeep.renew(internals, checkBeat)
	const closeAll = Upkeep.shutdown(internals, function()
		closing = true
	end)

	const state: Open.State = {
		name = name,
		template = template,
		storedTemplate = storedTemplate,
		reconcile = options.reconcile ~= false,
		plan = plan,
		config = config,
		base = base,
		sessions = sessions,
		opening = opening,
		onError = onError,
		closing = function(): boolean
			return closing
		end,
		prepare = Studio.guard(chosen, name, report, function()
			base.services = chosen.services
			base.dataStore = chosen.dataStore
		end),
		importer = options.import,
		beating = function(): boolean
			-- A load before the first beat landed beats first: its record must say the server beats.
			if not beating.ok then
				beatOnce()
			end
			return beating.ok
		end,
	}

	return {
		name = name,
		onError = onError,
		load = function(_: Store, key: string, loadOptions: LoadOptions?): LoadResult
			return Open.load(state, key, loadOptions)
		end,
		message = function(_: Store, key: string, message: { [any]: any }): Send.Result
			return Send.message(internals, key, message)
		end,
		versions = function(_: Store, key: string, query: Versions.Query?): { Versions.Version }
			return Versions.list(base, key, query)
		end,
		readVersion = function(_: Store, key: string, version: string): any
			return Versions.read(base, key, version)
		end,
		restore = function(_: Store, key: string, version: string): Versions.Restored
			return Versions.restore(base, key, version)
		end,
		receipts = function(_: Store, receiptOptions: Receipts.Options): (Receipts.Receipt) -> Receipts.Decision
			return Receipts.handler(internals, receiptOptions)
		end,
		close = function(_: Store)
			closeAll()
		end,
		trade = function(_: Store, keyA: string, keyB: string, change: (dataA: any, dataB: any) -> ()): Trade.Result
			return Trade.run(name, sessions, keyA, keyB, change)
		end,
		leaderboard = function(_: Store, boardName: string, query: Boards.Query?): { Boards.Entry }
			assert(boards, "KeepBlox: this store has no leaderboards")
			return boards:top(boardName, query)
		end,
		edit = function(_: Store, key: string, edit: (data: any) -> (), editOptions: Edit.Options?): Edit.Result
			return Edit.run(state, key, edit, editOptions)
		end,
		profiles = function(_: Store): { [string]: Profile.Profile }
			const open = {}
			for key, session in sessions do
				open[key] = session.profile
			end
			return open
		end,
	}
end

return Store
