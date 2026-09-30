--!strict
--- The live check's environment, run inside a Studio play server (see tests/live/README.md): virtual
--- servers over the real services, the log, and checks.
---
--- A virtual server is `RobloxServices.build()` with its own jobId, so several servers share one
--- process, one data store budget and the real DataStore, MessagingService and MemoryStore. `crash()`
--- freezes one where it stands: every call it makes from then on, and every call in flight when it
--- returns, never comes back, and its subscriptions hear nothing.
const HttpService = game:GetService("HttpService")
const DataStoreService = game:GetService("DataStoreService")

export type Server = {
	name: string,
	dead: boolean,
	services: any,
	crash: () -> (),
	open: (storeName: string?, options: { [string]: any }?) -> any,
}

const Env = {}

--> The only experience the live check may run in: GP_TEST, which nobody plays (roblox.env.example).
--> A live game shares its data store limits with every player, so a check there throttles their saves.
Env.TEST_UNIVERSE = 10767242853

Env.KeepBlox = nil :: any
Env.RobloxServices = nil :: any
Env.run = ""
Env.store = ""
Env.pass = 0
Env.fail = 0
Env.failures = {} :: { string }
Env.opened = {} :: { { store: any, server: Server } }
local lines: { string } = {}
local logValue: StringValue? = nil
local serial = 0

--> Starts a run: `KeepBlox` and `RobloxServices` are the modules under test, `log` shows the lines.
function Env.init(keepBlox: any, robloxServices: any, log: StringValue)
	assert(
		game.GameId == Env.TEST_UNIVERSE,
		`live check refused: GameId {game.GameId} is not the test experience {Env.TEST_UNIVERSE}`
	)
	Env.KeepBlox = keepBlox
	Env.RobloxServices = robloxServices
	Env.run = string.sub(HttpService:GenerateGUID(false), 1, 8)
	Env.store = `KB_LiveCheck_{Env.run}`
	Env.pass, Env.fail = 0, 0
	table.clear(Env.failures)
	table.clear(Env.opened)
	table.clear(lines)
	logValue = log
end

function Env.log(text: string)
	table.insert(lines, text)
	print(`[KBLIVE] {text}`)
	if logValue then
		logValue.Value = table.concat(lines, "\n")
	end
end

function Env.check(name: string, ok: boolean, detail: any?): boolean
	const suffix = if detail ~= nil then ` ({tostring(detail)})` else ""
	if ok then
		Env.pass += 1
		Env.log(`PASS {name}{suffix}`)
	else
		Env.fail += 1
		table.insert(Env.failures, name)
		Env.log(`FAIL {name}{suffix}`)
	end
	return ok
end

--> JSON of `value`, or a note when it has none.
function Env.encode(value: any): string
	const ok, text = pcall(HttpService.JSONEncode, HttpService, value)
	return if ok then text else `<{tostring(text)}>`
end

--> A key's value straight from the data store, uncached.
function Env.raw(storeName: string, key: string): any
	const options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	return (DataStoreService:GetDataStore(storeName):GetAsync(key, options))
end

--> Each budget of this server, as "type=n".
function Env.budget(types: { string }): string
	const parts = {}
	for _, requestType in types do
		const budget = DataStoreService:GetRequestBudgetForRequestType((Enum.DataStoreRequestType :: any)[requestType])
		table.insert(parts, `{requestType}={budget}`)
	end
	return table.concat(parts, " ")
end

const DATA_STORE = { "GetAsync", "SetAsync", "UpdateAsync", "RemoveAsync", "ListVersionsAsync", "GetVersionAsync" }
const ORDERED = { "GetAsync", "SetAsync", "UpdateAsync", "RemoveAsync", "GetSortedAsync" }
const MEMORY = { "GetAsync", "UpdateAsync", "RemoveAsync" }

function Env.server(name: string): Server
	const base = Env.RobloxServices.build()
	const services = table.clone(base)
	serial += 1
	local server: Server
	const function gate()
		if server.dead then
			while true do
				task.wait(3600)
			end
		end
	end
	const function proxy(inner: any, methods: { string }): any
		const wrapped = {}
		for _, method in methods do
			wrapped[method] = function(_: any, ...: any): ...any
				gate()
				const results = table.pack(inner[method](inner, ...))
				gate()
				return table.unpack(results, 1, results.n)
			end
		end
		return wrapped
	end
	services.jobId = `livecheck-{Env.run}-{name}-{serial}`
	services.dataStores = {
		GetDataStore = function(_: any, storeName: string, scope: string?): any
			return proxy(base.dataStores:GetDataStore(storeName, scope), DATA_STORE)
		end,
		GetOrderedDataStore = function(_: any, storeName: string, scope: string?): any
			return proxy(base.dataStores:GetOrderedDataStore(storeName, scope), ORDERED)
		end,
		GetRequestBudgetForRequestType = function(_: any, requestType: string): number
			return base.dataStores:GetRequestBudgetForRequestType(requestType)
		end,
	}
	services.memory = {
		GetSortedMap = function(_: any, mapName: string): any
			return proxy(base.memory:GetSortedMap(mapName), MEMORY)
		end,
	}
	services.messaging = {
		PublishAsync = function(_: any, topic: string, message: any)
			gate()
			base.messaging:PublishAsync(topic, message)
			gate()
		end,
		SubscribeAsync = function(_: any, topic: string, callback: (any) -> ()): any
			gate()
			const connection = base.messaging:SubscribeAsync(topic, function(message: any)
				if not server.dead then
					callback(message)
				end
			end)
			gate()
			return connection
		end,
	}
	services.clock = {
		now = base.clock.now,
		time = base.clock.time,
		wait = function(seconds: number?): number
			gate()
			const waited = task.wait(seconds)
			gate()
			return waited
		end,
		spawn = function(target: any, ...: any)
			if not server.dead then
				task.spawn(target, ...)
			end
		end,
		cancel = base.clock.cancel,
	}
	-- Shutdown is the check's to call (`store:close()`), not the play session's.
	services.bindToClose = function(_: () -> ()) end
	server = {
		name = name,
		dead = false,
		services = services,
		crash = function()
			server.dead = true
		end,
		open = function(storeName: string?, options: { [string]: any }?): any
			const given: { [string]: any } = if options then table.clone(options) else {}
			given.services = services
			if given.template == nil and given.schema == nil then
				given.template = { coins = 0, list = {}, name = "" }
			end
			const store = Env.KeepBlox.store(storeName or Env.store, given)
			table.insert(Env.opened, { store = store, server = server })
			return store
		end,
	}
	return server
end

--> Waits for `predicate` up to `limit` seconds; returns whether it held and the seconds taken.
function Env.waitFor(limit: number, predicate: () -> boolean): (boolean, number)
	const started = os.clock()
	while os.clock() - started < limit do
		if predicate() then
			return true, os.clock() - started
		end
		task.wait(0.05)
	end
	return predicate(), os.clock() - started
end

--> Closes the stores the last step opened on servers still alive.
function Env.closeOpened()
	for _, opened in Env.opened do
		if not opened.server.dead then
			pcall(opened.store.close, opened.store)
		end
	end
	table.clear(Env.opened)
end

return Env
