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
const Claim = require("./Claim")
const Config = require("./Config")
const Inbox = require("./Inbox")
const Messages = require("./Messages")
const MockServices = require("./MockServices")
const Profile = require("./Profile")
const Record = require("./Record")
const Send = require("./Send")
const Serial = require("./Serial")
const Services = require("./Services")
const Session = require("./Session")
const Signal = require("./Signal")
const Upkeep = require("./Upkeep")
const Validate = require("./Validate")

export type Options = {
	--> The data a new profile starts with.
	template: { [any]: any },
	--> The engine services; the real ones by default. Tests pass fakes.
	services: Services.Services?,
	--> Overrides for `Config.DEFAULT`.
	config: { [string]: number }?,
	--> Keep profiles in memory, never in a live data store: `true`, or the name of a scratch set. In
	--> Studio without API access this happens on its own, after a read-only check.
	mock: (boolean | string)?,
}

export type LoadOptions = {
	--> Polled while the load waits; true gives up (the player left).
	cancel: (() -> boolean)?,
	--> Take the key at once from whoever holds it, as ProfileStore's `Steal = true`. For recovering a
	--> key stuck on a dead server by hand; a normal load never needs it.
	steal: boolean?,
}

export type LoadResult = { ok: true, profile: Profile.Profile } | { ok: false, reason: Claim.Failure | "open" }

export type Store = {
	read name: string,
	--> Fires `(key, message)` for every problem worth logging: failed calls, refused data, quarantine.
	read onError: Signal.Signal<string, string>,
	load: (self: Store, key: string, options: LoadOptions?) -> LoadResult,
	--> The open profiles, by key.
	profiles: (self: Store) -> { [string]: Profile.Profile },
	--> Queues an offline message for `key`, open or not (see Send).
	message: (self: Store, key: string, message: { [any]: any }) -> Send.Result,
}

const Store = {}

-- A stable spread of renewal times over the interval, from the key alone.
const function offset(key: string): number
	local hash = 0
	for index = 1, #key do
		hash = (hash * 31 + string.byte(key, index)) % 1000
	end
	return hash / 1000
end

function Store.new(name: string, options: Options): Store
	assert(type(name) == "string" and #name > 0, "KeepBlox: a store needs a name")
	assert(type(options) == "table" and type(options.template) == "table", "KeepBlox: a store needs a template")
	assert(Validate.check(options.template, "template"), "KeepBlox: the template must be storable")
	const config = Config.resolve(options.config)
	local services = options.services or require("./RobloxServices").build()
	if options.mock then
		services = MockServices.wrap(services, if type(options.mock) == "string" then options.mock else "scratch")
	end
	-- Studio without API access is found by a read on first load; a write would touch a live key.
	local checked = options.mock ~= nil or not services.isStudio
	const clock = services.clock
	const template = Record.copy(options.template)
	const onError: Signal.Signal<string, string> = Signal.new(clock.spawn)
	const sessions: { [string]: Session.Session } = {}
	const opening: { [string]: boolean } = {}
	local closing = false

	const base: Session.Context = {
		services = services,
		config = config,
		dataStore = services.dataStores:GetDataStore(name),
		identity = { placeId = services.placeId, jobId = services.jobId, guid = "" },
		report = function(key: string, message: string)
			onError:fire(key, message)
		end,
		closing = function(): boolean
			return closing
		end,
		forget = function(session: Session.Session)
			if sessions[session.key] == session then
				sessions[session.key] = nil
			end
		end,
	}

	const internals: Upkeep.Internals = {
		context = function(): Session.Context
			return base
		end,
		sessions = sessions,
		closing = function(): boolean
			return closing
		end,
	}
	Upkeep.renew(internals)
	Upkeep.shutdown(internals, function()
		closing = true
	end)

	const checking = Serial.new(clock)
	const function checkAccess()
		checking:run(function()
			if checked then
				return
			end
			const ok, problem = pcall(base.dataStore.GetAsync, base.dataStore, "__KeepBlox_access_check", false)
			if not ok and MockServices.isNoAccess(tostring(problem)) then
				services = MockServices.wrap(services, "studio")
				base.services = services
				base.dataStore = services.dataStores:GetDataStore(name)
				onError:fire("", "Studio has no API access: profiles are kept in memory, and nothing is saved")
			end
			checked = true
		end)
	end

	return {
		name = name,
		onError = onError,
		load = function(_: Store, key: string, loadOptions: LoadOptions?): LoadResult
			assert(type(key) == "string" and #key > 0 and #key <= 50, "KeepBlox: a key is 1-50 characters")
			if sessions[key] or opening[key] then
				return { ok = false, reason = "open" }
			end
			opening[key] = true
			if not checked then
				checkAccess()
			end
			const context = table.clone(base)
			context.identity = { placeId = services.placeId, jobId = services.jobId, guid = services.guid() }
			const listener =
				{ session = nil :: Session.Session?, connection = nil :: Services.Connection?, done = false }
			Upkeep.listen(services, context.identity.guid, listener)
			const claim = Claim.open(
				context,
				name,
				key,
				template,
				loadOptions and loadOptions.cancel,
				loadOptions ~= nil and loadOptions.steal == true
			)
			opening[key] = nil
			if not claim.ok then
				listener.done = true
				if listener.connection then
					listener.connection:Disconnect()
				end
				return { ok = false, reason = claim.reason }
			end
			const record = claim.record
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
			const encoded = Validate.check(record.Data, "Data", nil, Session.slicer(clock))
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
				nextRenew = clock.now() + config.renew * (0.5 + offset(key) / 2),
				serial = Serial.new(clock),
				lastProblem = nil :: string?,
				inbox = Inbox.new(clock, function()
					session.saveSoon = true
				end, function(message: string)
					onError:fire(key, message)
				end),
				saveSoon = false,
				listener = listener,
			}
			listener.session = session
			session.inbox:receive(Messages.list(record))
			sessions[key] = session
			return { ok = true, profile = profile }
		end,
		message = function(_: Store, key: string, message: { [any]: any }): Send.Result
			return Send.message(internals, key, message)
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
