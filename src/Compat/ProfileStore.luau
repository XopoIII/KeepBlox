--!strict
--- ProfileStore's API over KeepBlox, so a game switches by changing one `require`:
---
---     local ProfileStore = require(path.to.KeepBlox.Compat.ProfileStore)
---     local PlayerStore = ProfileStore.New("PlayerStore", TEMPLATE)
---     local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
---         Cancel = function() return player.Parent ~= Players end,
---     })
---
--- Keys stay where they are and in the same format, and old and new servers can run side by side
--- during the rollout (tests/scenario/Compat.luau). Where KeepBlox deliberately differs, it says so;
--- it never imitates a ProfileStore bug:
--- - A key holding something that is not a profile is quarantined and the session returns nil. It is
---   not overwritten with the template. `OnOverwrite` never fires; `OnError` reports it.
--- - Data that cannot be stored (NaN, bad UTF-8, cycles, too large) is refused with its path through
---   `OnError`, instead of failing every save silently.
--- - When a session ends, `Data` is frozen: late writes fail loudly instead of being lost quietly.
--- - The owner saves on KeepBlox's schedule (a MemoryStore snapshot every beat, the data store every
---   `renew`), not every 300 s. `AUTO_SAVE_PERIOD`,
---   `LOAD_REPEAT_PERIOD` and `FIRST_LOAD_REPEAT` are accepted by `SetConstant` but have no effect.
--- - `KeyInfo` is nil. `MessageHandler` works on active profiles only, not in view mode.
--- - A full message queue refuses `MessageAsync` (false) instead of dropping the oldest message.
const Config = require("../Config")
const CompatProfile = require("./Profile")
const MockServices = require("../MockServices")
const Record = require("../Record")
const Services = require("../Services")
const Store = require("../Store")

-- ProfileStore's constants, and the KeepBlox setting each one maps to (false: accepted, no effect).
const CONSTANTS: { [string]: string | false } = {
	AUTO_SAVE_PERIOD = false,
	LOAD_REPEAT_PERIOD = false,
	FIRST_LOAD_REPEAT = false,
	SESSION_STEAL = "profileStoreSteal",
	ASSUME_DEAD = "profileStoreDead",
	START_SESSION_TIMEOUT = "loadTimeout",
	CRITICAL_STATE_ERROR_COUNT = false,
	CRITICAL_STATE_ERROR_EXPIRE = false,
	CRITICAL_STATE_EXPIRE = false,
	MAX_MESSAGE_QUEUE = false,
}

-- ProfileStore's critical state: this many errors within this many seconds.
const CRITICAL_ERRORS = 5
const CRITICAL_WINDOW = 120

const Compat = {}

--> A fresh ProfileStore module over `services` (the real engine's by default, built on first use).
function Compat.withServices(given: Services.Services?): any
	local services: Services.Services? = given
	const overrides: { [string]: number } = {}
	const errors: { number } = {}
	const module: any = {
		IsClosing = false,
		IsCriticalState = false,
		DataStoreState = "Access",
	}

	const function engine(): Services.Services
		if services == nil then
			services = require("../RobloxServices").build()
		end
		return services :: Services.Services
	end

	const function signal(): any
		return CompatProfile.signal(function(fn: (...any) -> (), ...: any)
			engine().clock.spawn(fn, ...)
		end)
	end
	module.OnError = signal()
	module.OnOverwrite = signal()
	module.OnCriticalToggle = signal()

	const function noteError(message: string, storeName: string, key: string)
		module.OnError:Fire(message, storeName, key)
		const now = engine().clock.now()
		table.insert(errors, now)
		while errors[1] and now - errors[1] > CRITICAL_WINDOW do
			table.remove(errors, 1)
		end
		const critical = #errors >= CRITICAL_ERRORS
		if critical ~= module.IsCriticalState then
			module.IsCriticalState = critical
			module.OnCriticalToggle:Fire(critical)
		end
	end

	function module.SetConstant(name: string, value: number)
		const setting = CONSTANTS[name]
		assert(setting ~= nil, `ProfileStore.SetConstant: unknown constant "{name}"`)
		assert(type(value) == "number", "ProfileStore.SetConstant: the value must be a number")
		if setting then
			overrides[setting] = value
		end
	end

	const function newStore(storeName: string, template: { [any]: any }, mock: boolean): any
		local core: Store.Store? = nil
		local closingBound = false
		const function open(): Store.Store
			if core == nil then
				const base = engine()
				const created = Store.new(storeName, {
					template = template,
					services = base,
					-- SetConstant names its settings at run time, which `Config.resolve` checks there.
					config = Config.resolve(overrides :: any) :: any,
					mock = if mock then `ProfileStore.Mock/{storeName}` else nil,
					-- ProfileStore fills from the template only when the game calls Reconcile.
					reconcile = false,
				})
				created.onError:connect(function(key: string, message: string)
					noteError(message, storeName, key)
				end)
				if not closingBound then
					closingBound = true
					base.bindToClose(function()
						module.IsClosing = true
					end)
				end
				core = created
			end
			return core :: Store.Store
		end
		const function dataStore(): Services.DataStore
			const base = engine()
			const source = if mock then MockServices.wrap(base, `ProfileStore.Mock/{storeName}`) else base
			return source.dataStores:GetDataStore(storeName)
		end

		const store: any = { Name = storeName }

		function store.StartSessionAsync(
			_: any,
			key: string,
			params: { Steal: boolean?, Cancel: (() -> boolean)? }?
		): any
			const result = open():load(key, {
				cancel = params and params.Cancel,
				steal = params ~= nil and params.Steal == true,
			})
			if not result.ok then
				return nil
			end
			return CompatProfile.active(result.profile, template, engine())
		end

		function store.GetAsync(_: any, key: string, version: string?): any
			const handle = dataStore()
			const value = if version then handle:GetVersionAsync(key, version) else handle:GetAsync(key, false)
			if Record.classify(value) ~= "profile" then
				return nil
			end
			return CompatProfile.view(value, template, engine(), function(data: any)
				handle:UpdateAsync(key, function(current: any): any
					const record = if Record.classify(current) == "profile"
						then current
						else Record.fresh(template, engine().clock.time())
					record.Data = data
					record.MetaData.ActiveSession = nil
					record.MetaData.ForceLoadSession = nil
					return record
				end)
			end)
		end

		function store.RemoveAsync(_: any, key: string): boolean
			return (pcall(function()
				dataStore():RemoveAsync(key)
			end))
		end

		function store.MessageAsync(_: any, key: string, message: { [any]: any }): boolean
			return open():message(key, message).ok
		end

		-- ProfileStore takes dates as DateTime or Unix milliseconds.
		const function millis(date: any): number
			if type(date) == "number" then
				return date
			elseif date ~= nil then
				return date.UnixTimestampMillis
			end
			return 0
		end

		function store.VersionQuery(_: any, key: string, direction: any?, minDate: any?, maxDate: any?): any
			-- Enum.SortDirection.Descending, read by its Name.
			local name = tostring(direction)
			pcall(function()
				name = (direction :: any).Name
			end)
			const newestFirst = name == "Descending"
			local found: { any }? = nil
			local nextIndex = 1
			return {
				NextAsync = function(_: any): any
					if found == nil then
						found = open():versions(key, {
							newestFirst = newestFirst,
							from = millis(minDate),
							to = millis(maxDate),
							limit = 1024,
						})
					end
					const list = found :: { any }
					while nextIndex <= #list do
						const entry = list[nextIndex]
						nextIndex += 1
						if not entry.deleted then
							const profile = store:GetAsync(key, entry.version)
							if profile then
								return profile
							end
						end
					end
					return nil
				end,
			}
		end

		return store
	end

	function module.New(storeName: string, template: { [any]: any }?): any
		assert(type(storeName) == "string" and #storeName > 0, "ProfileStore.New: a store needs a name")
		const resolved = template or {}
		const store = newStore(storeName, resolved, false)
		store.Mock = newStore(storeName, resolved, true)
		return store
	end

	return module
end

const default = Compat.withServices(nil)
--> Another module instance over given services (tests, or a custom engine).
default.withServices = Compat.withServices
return default
