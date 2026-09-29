--!strict
--- The engine's scheduling and small globals for one virtual server: `task`, `coroutine`, `RunService`,
--- `Enum`, `DateTime`, `typeof`, `os`.
---
--- The engine's rules are kept (https://create.roblox.com/docs/reference/engine/libraries/task):
--- - `task.spawn` runs a function or thread at once, up to its first yield;
--- - `task.defer` runs it later, and returns the thread;
--- - `task.wait()` with no argument waits one frame; `task.cancel` stops a thread for good;
--- - `coroutine.resume` and `coroutine.wrap` of a thread that then waits hand control back to the
---   resumer; `coroutine.close` also stops the thread's wait.
---
--- Frames are coarser than a live server's 60 Hz (`frame`, 0.1 s by default): a frame-based loop sees
--- the same time pass in fewer steps.
const Scheduler = require("@fakes/Scheduler")
const World = require("@fakes/World")

export type Engine = {
	task: { [string]: any },
	coroutine: { [string]: any },
	os: { [string]: any },
	RunService: { [string]: any },
	Enum: { [string]: any },
	DateTime: { [string]: any },
	typeof: (value: any) -> string,
	--> Waits at least one frame.
	wait: (dt: number?) -> number,
}

-- A value that `typeof` names as the engine would (an EnumItem, an Instance): tables marked with it.
const TYPE_KEY = "__RobloxEnvType"

const Engine = {}

--> An enum of `names`, whose items `typeof` calls "EnumItem".
function Engine.enum(enumName: string, names: { string }): { [string]: any }
	const enum: { [string]: any } = {}
	for index, name in names do
		enum[name] = table.freeze({ [TYPE_KEY] = "EnumItem", Name = name, Value = index - 1, EnumType = enum })
	end
	return table.freeze(setmetatable(enum, {
		__tostring = function(): string
			return enumName
		end,
	}))
end

--> Marks `value` so `typeof` names it `kind`.
function Engine.mark(value: { [any]: any }, kind: string): { [any]: any }
	value[TYPE_KEY] = kind
	return value
end

-- A signal of frames: `Connect` runs each listener in its own thread every frame; `Wait` waits one.
const function frameSignal(scheduler: Scheduler.Scheduler, server: World.Server, wait: (number?) -> number): any
	const listeners: { (number) -> () } = {}
	local beating = false
	return {
		Connect = function(_: any, fn: (number) -> ())
			table.insert(listeners, fn)
			if not beating then
				beating = true
				scheduler:spawn(function()
					while true do
						const dt = wait()
						for _, listener in table.clone(listeners) do
							scheduler:resume(function()
								listener(dt)
							end)
						end
					end
				end, server.name)
			end
			return {
				Connected = true,
				Disconnect = function()
					const index = table.find(listeners, fn)
					if index then
						table.remove(listeners, index)
					end
				end,
			}
		end,
		Wait = function(_: any): number
			return wait()
		end,
	}
end

function Engine.new(world: World.World, server: World.Server, frame: number, isStudio: boolean): Engine
	const scheduler = world.scheduler
	const clock = server.services.clock

	const function wait(dt: number?): number
		return clock.wait(if dt == nil or dt < frame then frame else dt)
	end

	const task = {
		wait = wait,
		spawn = function(target: any, ...: any): any
			const co = if type(target) == "thread" then target else coroutine.create(target)
			scheduler:resume(co, nil, ...)
			return co
		end,
		defer = function(target: any, ...: any): thread
			const co = if type(target) == "thread" then target else coroutine.create(target)
			scheduler:spawn(function(...: any)
				scheduler:resume(co, nil, ...)
			end, nil, ...)
			return co
		end,
		delay = function(seconds: number, target: any, ...: any): thread
			const co = if type(target) == "thread" then target else coroutine.create(target)
			scheduler:spawn(function(...: any)
				wait(seconds)
				scheduler:resume(co, nil, ...)
			end, nil, ...)
			return co
		end,
		cancel = function(co: thread)
			scheduler:cancel(co)
			if coroutine.status(co) == "suspended" then
				coroutine.close(co)
			end
		end,
	}

	const coroutineTable = table.clone(coroutine)
	coroutineTable.resume = function(co: thread, ...: any): ...any
		return scheduler:resume(co, nil, ...)
	end
	coroutineTable.wrap = function(fn: (...any) -> ...any): (...any) -> ...any
		return scheduler:wrap(fn)
	end
	coroutineTable.close = function(co: thread): (boolean, any)
		scheduler:cancel(co)
		return coroutine.close(co)
	end

	const osTable = table.clone(os)
	osTable.time = function(): number
		return clock.time()
	end
	osTable.clock = function(): number
		return clock.now()
	end

	const heartbeat = frameSignal(scheduler, server, wait)
	const RunService = {
		IsStudio = function(_: any): boolean
			return isStudio
		end,
		IsServer = function(_: any): boolean
			return true
		end,
		Heartbeat = heartbeat,
		PostSimulation = heartbeat,
		Stepped = heartbeat,
	}

	const DateTime = {
		now = function(): any
			const millis = math.floor((clock.time() + (clock.now() % 1)) * 1000)
			return { UnixTimestampMillis = millis, UnixTimestamp = millis // 1000 }
		end,
	}

	const Enum = {
		SortDirection = Engine.enum("SortDirection", { "Ascending", "Descending" }),
		DataStoreRequestType = Engine.enum("DataStoreRequestType", {
			"GetAsync",
			"SetIncrementAsync",
			"UpdateAsync",
			"GetSortedAsync",
			"SetIncrementSortedAsync",
			"OnUpdate",
			"ListAsync",
			"GetVersionAsync",
			"RemoveVersionAsync",
			"StandardRead",
			"StandardWrite",
			"StandardList",
			"StandardRemove",
			"OrderedRead",
			"OrderedWrite",
			"OrderedList",
			"OrderedRemove",
		}),
	}

	return {
		task = task,
		coroutine = coroutineTable :: any,
		os = osTable :: any,
		RunService = RunService,
		Enum = Enum,
		DateTime = DateTime,
		typeof = function(value: any): string
			if type(value) == "table" then
				const kind = rawget(value, TYPE_KEY)
				if kind ~= nil then
					return tostring(kind)
				end
			end
			return typeof(value)
		end,
		wait = wait,
	}
end

return Engine
