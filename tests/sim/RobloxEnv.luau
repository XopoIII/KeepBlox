--!strict
--- The engine globals one virtual server gives the Roblox code it runs: `game`, `task`, `os`,
--- `coroutine`, `Enum`, `Instance`, `script`, `warn` and `print`, all over the fakes.
---
--- This is how unmodified Roblox modules (the vendored ProfileStore) run in the simulator. Each server
--- loads its own copy of a module into its own environment, so module state is per server, as it is
--- in Roblox. The engine's scheduling rules are kept:
--- - `task.spawn` runs a function or thread at once, up to its first yield;
--- - `task.defer` runs it later;
--- - `task.wait()` with no argument waits one frame;
--- - `coroutine.resume` of a thread that then waits hands control back to the resumer.
---
--- Frames are coarser than a live server's 60 Hz (`frame`, 0.1 s by default): a frame-based loop sees
--- the same time pass in fewer steps.
const Scheduler = require("@fakes/Scheduler")
const World = require("@fakes/World")
const fs = require("@lune/fs")
const luau = require("@lune/luau")

export type Env = {
	read server: World.Server,
	read globals: { [string]: any },
	--> Everything the code printed or warned, in order.
	read log: { string },
	--> Runs a module's `source` in this server's environment, and returns what it returns. It must be
	--> called from a thread of this server. Read the source first, outside any simulated thread, with
	--> `RobloxEnv.read`.
	load: (self: Env, source: string, name: string) -> any,
}

export type Options = {
	frame: number?,
	isStudio: boolean?,
}

const SortDirection = table.freeze({
	Ascending = table.freeze({ Name = "Ascending" }),
	Descending = table.freeze({ Name = "Descending" }),
})

const RobloxEnv = {}

function RobloxEnv.new(world: World.World, server: World.Server, options: Options?): Env
	const scheduler: Scheduler.Scheduler = world.scheduler
	const services = server.services
	const clock = services.clock
	const frame = if options and options.frame then options.frame else 0.1
	const log: { string } = {}

	const function wait(dt: number?): number
		return clock.wait(if dt == nil or dt < frame then frame else dt)
	end

	const task = {
		wait = wait,
		spawn = function(target: any, ...: any): any
			scheduler:resume(target, nil, ...)
			return target
		end,
		defer = function(target: any, ...: any)
			if type(target) == "thread" then
				scheduler:spawn(function(...: any)
					scheduler:resume(target, nil, ...)
				end, nil, ...)
			else
				scheduler:spawn(target, nil, ...)
			end
		end,
		delay = function(seconds: number, fn: (...any) -> (), ...: any)
			scheduler:spawn(function(...: any)
				wait(seconds)
				fn(...)
			end, nil, ...)
		end,
	}

	const heartbeat: { (number) -> () } = {}
	local beating = false
	const RunService = {
		IsStudio = function(_: any): boolean
			return options ~= nil and options.isStudio == true
		end,
		Heartbeat = {
			Connect = function(_: any, fn: (number) -> ())
				table.insert(heartbeat, fn)
				if not beating then
					beating = true
					scheduler:spawn(function()
						while true do
							const dt = wait(frame)
							for _, listener in table.clone(heartbeat) do
								-- Each listener runs in its own thread, as a connected handler does.
								scheduler:resume(function()
									listener(dt)
								end)
							end
						end
					end, server.name)
				end
				return {
					Disconnect = function()
						const index = table.find(heartbeat, fn)
						if index then
							table.remove(heartbeat, index)
						end
					end,
				}
			end,
		},
	}

	const DataStoreService = {
		GetDataStore = function(_: any, name: string, scope: string?, _options: any): any
			const store = services.dataStores:GetDataStore(name, scope)
			return {
				GetAsync = function(_: any, key: string, getOptions: any): (any, any)
					return store:GetAsync(key, if getOptions then getOptions.UseCache else nil)
				end,
				SetAsync = function(_: any, key: string, value: any, userIds: { number }?): string
					return store:SetAsync(key, value, userIds)
				end,
				UpdateAsync = function(_: any, key: string, transform: any): (any, any)
					return store:UpdateAsync(key, transform)
				end,
				RemoveAsync = function(_: any, key: string): (any, any)
					return store:RemoveAsync(key)
				end,
				GetVersionAsync = function(_: any, key: string, version: string): (any, any)
					return store:GetVersionAsync(key, version)
				end,
				ListVersionsAsync = function(
					_: any,
					key: string,
					direction: any,
					minDate: number?,
					maxDate: number?,
					pageSize: number?
				): any
					const ascending = direction ~= SortDirection.Descending
					return store:ListVersionsAsync(key, ascending, minDate, maxDate, pageSize)
				end,
			}
		end,
		GetRequestBudgetForRequestType = function(_: any, requestType: any): number
			return services.dataStores:GetRequestBudgetForRequestType(requestType)
		end,
	}

	const MessagingService = {
		PublishAsync = function(_: any, topic: string, message: any)
			services.messaging:PublishAsync(topic, message)
		end,
		SubscribeAsync = function(_: any, topic: string, callback: (any) -> ()): any
			return services.messaging:SubscribeAsync(topic, callback)
		end,
	}

	const HttpService = {
		GenerateGUID = function(_: any, braces: boolean?): string
			const random = scheduler.random
			const hex = function(digits: number): string
				local text = ""
				for _ = 1, digits do
					text ..= string.format("%X", random:integer(0, 15))
				end
				return text
			end
			const guid = `{hex(8)}-{hex(4)}-{hex(4)}-{hex(4)}-{hex(12)}`
			return if braces == false then guid else `\{{guid}\}`
		end,
	}

	const byName: { [string]: any } = {
		DataStoreService = DataStoreService,
		MessagingService = MessagingService,
		HttpService = HttpService,
		RunService = RunService,
	}

	const game = {
		PlaceId = services.placeId,
		JobId = services.jobId,
		GetService = function(_: any, name: string): any
			return byName[name] or error(`RobloxEnv: no fake for service {name}`, 2)
		end,
		BindToClose = function(_: any, callback: () -> ())
			services.bindToClose(callback)
		end,
	}

	const osTable = table.clone(os)
	osTable.time = function(): number
		return clock.time()
	end
	osTable.clock = function(): number
		return clock.now()
	end

	const coroutineTable = table.clone(coroutine)
	coroutineTable.resume = function(co: thread, ...: any): ...any
		return scheduler:resume(co, nil, ...)
	end

	const function line(...: any): string
		const parts = table.pack(...)
		const words = {}
		for index = 1, parts.n do
			words[index] = tostring(parts[index])
		end
		return table.concat(words, " ")
	end

	const globals: { [string]: any } = {
		game = game,
		task = task,
		os = osTable,
		coroutine = coroutineTable,
		Enum = { SortDirection = SortDirection },
		Instance = {
			new = function(className: string): any
				if className == "DataStoreOptions" then
					return { SetExperimentalFeatures = function() end }
				end
				error(`RobloxEnv: Instance.new("{className}") is not faked`, 2)
			end,
		},
		warn = function(...: any)
			table.insert(log, "warn: " .. line(...))
		end,
		print = function(...: any)
			table.insert(log, line(...))
		end,
	}

	return {
		server = server,
		globals = globals,
		log = log,
		load = function(self: Env, source: string, name: string): any
			const env = table.clone(self.globals)
			env.script = { Name = name }
			const chunk = luau.load(source, { debugName = name, environment = env })
			return chunk()
		end,
	}
end

--> A module's source text. Call it outside simulated threads: Lune's file functions yield to Lune's
--> own scheduler, and a simulated thread that yields there is resumed outside the simulation.
function RobloxEnv.read(path: string): string
	return fs.readFile(path)
end

return RobloxEnv
