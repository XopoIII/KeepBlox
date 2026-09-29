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
const Profile = require("./Profile")
const Record = require("./Record")
const Serial = require("./Serial")
const Services = require("./Services")
const Session = require("./Session")
const Signal = require("./Signal")
const Validate = require("./Validate")

export type Options = {
	--> The data a new profile starts with.
	template: { [any]: any },
	--> The engine services; the real ones by default. Tests pass fakes.
	services: Services.Services?,
	--> Overrides for `Config.DEFAULT`.
	config: { [string]: number }?,
}

export type LoadOptions = {
	--> Polled while the load waits; true gives up (the player left).
	cancel: (() -> boolean)?,
}

export type LoadResult = { ok: true, profile: Profile.Profile } | { ok: false, reason: Claim.Failure | "open" }

export type Store = {
	read name: string,
	--> Fires `(key, message)` for every problem worth logging: failed calls, refused data, quarantine.
	read onError: Signal.Signal<string, string>,
	load: (self: Store, key: string, options: LoadOptions?) -> LoadResult,
	--> The open profiles, by key.
	profiles: (self: Store) -> { [string]: Profile.Profile },
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
	const services = options.services or require("./RobloxServices").build()
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

	const function budgetLeft(): boolean
		const dataStores = services.dataStores
		return dataStores:GetRequestBudgetForRequestType("StandardWrite") > 0
			and dataStores:GetRequestBudgetForRequestType("StandardRead") > 0
	end

	clock.spawn(function()
		while not closing do
			clock.wait(1)
			const now = clock.now()
			for _, session in sessions do
				if session.active and now >= session.nextRenew and not session.serial:busy() then
					if not budgetLeft() then
						break
					end
					session.nextRenew = now + config.renew
					clock.spawn(Session.save, session.context, session, true)
				end
			end
		end
	end)

	services.bindToClose(function()
		closing = true
		local pending = 0
		for _, session in sessions do
			pending += 1
			clock.spawn(function()
				Session.release(session.context, session, "shutdown")
				pending -= 1
			end)
		end
		const started = clock.now()
		while pending > 0 and clock.now() - started < config.shutdownDeadline do
			clock.wait(0.1)
		end
	end)

	-- Listens for hand-over requests to this session's GUID. It subscribes before the claim, so a
	-- request that arrives right after the key is taken is not missed. The subscription can hang (as
	-- in Team Test), so it never holds up the load.
	const function listen(
		guid: string,
		target: { session: Session.Session?, connection: Services.Connection?, done: boolean }
	)
		clock.spawn(function()
			const ok, connection = pcall(function()
				return services.messaging:SubscribeAsync(`PS_{guid}`, function(message: Services.Message)
					const data = message.Data
					const session = target.session
					if
						session
						and type(data) == "table"
						and data.LoadCount == session.loadCount
						and data.EndSession
					then
						Session.release(session.context, session, "handedOver")
					end
				end)
			end)
			if ok then
				if target.done then
					connection:Disconnect()
				else
					target.connection = connection
				end
			end
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
			const context = table.clone(base)
			context.identity = { placeId = services.placeId, jobId = services.jobId, guid = services.guid() }
			const listener =
				{ session = nil :: Session.Session?, connection = nil :: Services.Connection?, done = false }
			listen(context.identity.guid, listener)
			const claim = Claim.open(context, name, key, template, loadOptions and loadOptions.cancel)
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
			})
			const encoded = Validate.check(record.Data, "Data")
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
				listener = listener,
			}
			listener.session = session
			sessions[key] = session
			return { ok = true, profile = profile }
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
