--!strict
--- Just enough of the Instance tree for data libraries: folders and ModuleScripts that `require` loads
--- (so `require(script.Parent.Promise)` works), `BindableEvent`, and players.
---
--- Children are reached as fields (`script.Signal`) and through `FindFirstChild` / `WaitForChild`,
--- as in the engine. A ModuleScript runs once per server, with its own `script`, and `require` returns
--- the cached result after that (https://create.roblox.com/docs/reference/engine/globals/LuaGlobals#require).
--- Signals fire deferred, the engine's default `SignalBehavior`: a handler runs later, in its own thread.
const Engine = require("./Engine")

--> A directory read from disk: files become ModuleScripts, a directory with `init.luau` (or `.lua`)
--> becomes a ModuleScript with that source, any other directory a Folder.
export type Node = { name: string, source: string?, children: { Node } }

export type Instances = {
	--> Builds `node` as instances under `parent` (nil: no parent) and returns its root.
	mount: (node: Node, parent: any?) -> any,
	--> A new instance of `className` (a Folder, a BindableEvent, a DataStore options object).
	new: (className: string) -> any,
	--> Runs a ModuleScript (the `require` global); anything else goes to `fallback`.
	require: (target: any) -> any,
	--> A connectable signal, fired deferred.
	signal: () -> any,
}

const Instances = {}

function Instances.new(
	engine: Engine.Engine,
	load: (source: string, name: string, script: any) -> any,
	fallback: (target: any) -> any
): Instances
	const task = engine.task
	const results: { [any]: { value: any } } = {}

	const function signal(): any
		const listeners: { (...any) -> () } = {}
		const self = {}
		function self.Connect(_: any, fn: (...any) -> ()): any
			table.insert(listeners, fn)
			return {
				Connected = true,
				Disconnect = function(connection: any)
					connection.Connected = false
					const index = table.find(listeners, fn)
					if index then
						table.remove(listeners, index)
					end
				end,
			}
		end
		function self.Once(this: any, fn: (...any) -> ()): any
			local connection: any = nil
			connection = this:Connect(function(...: any)
				connection:Disconnect()
				fn(...)
			end)
			return connection
		end
		function self.Wait(this: any): ...any
			const co = coroutine.running()
			this:Once(function(...: any)
				task.spawn(co, ...)
			end)
			return coroutine.yield()
		end
		function self.Fire(_: any, ...: any)
			for _, listener in table.clone(listeners) do
				task.defer(listener, ...)
			end
		end
		return self
	end

	const function instance(className: string, name: string): any
		const children: { any } = {}
		const self: any = { ClassName = className, Name = name, Parent = nil }
		const methods = {
			GetChildren = function(_: any): { any }
				return table.clone(children)
			end,
			FindFirstChild = function(_: any, childName: string): any
				for _, child in children do
					if child.Name == childName then
						return child
					end
				end
				return nil
			end,
			WaitForChild = function(this: any, childName: string): any
				return this:FindFirstChild(childName) or error(`RobloxEnv: {name} has no child {childName}`, 2)
			end,
			IsA = function(_: any, other: string): boolean
				return other == className or other == "Instance"
			end,
			IsDescendantOf = function(_: any, ancestor: any): boolean
				local node = self.Parent
				while node ~= nil do
					if node == ancestor then
						return true
					end
					node = node.Parent
				end
				return false
			end,
			Destroy = function(_: any)
				self.Parent = nil
			end,
			__children = children,
		}
		Engine.mark(self, "Instance")
		return setmetatable(self, {
			__index = function(_: any, key: string): any
				const method = (methods :: any)[key]
				if method ~= nil then
					return method
				end
				for _, child in children do
					if child.Name == key then
						return child
					end
				end
				return nil
			end,
		})
	end

	const function parentTo(child: any, parent: any?)
		child.Parent = parent
		if parent then
			table.insert(parent.__children, child)
		end
	end

	const function mount(node: Node, parent: any?): any
		const root = instance(if node.source then "ModuleScript" else "Folder", node.name)
		if node.source then
			rawset(root, "__source", node.source)
		end
		parentTo(root, parent)
		for _, child in node.children do
			mount(child, root)
		end
		return root
	end

	const function new(className: string): any
		if className == "BindableEvent" then
			const event = instance(className, className)
			const inner = signal()
			rawset(event, "Event", inner)
			rawset(event, "Fire", function(_: any, ...: any)
				inner:Fire(...)
			end)
			return event
		elseif className == "DataStoreOptions" then
			return { SetExperimentalFeatures = function() end }
		elseif className == "DataStoreGetOptions" or className == "DataStoreSetOptions" then
			local metadata = {}
			return {
				UseCache = true,
				SetMetadata = function(_: any, value: any)
					metadata = value
				end,
				GetMetadata = function(_: any): any
					return metadata
				end,
			}
		elseif className == "Folder" then
			return instance(className, className)
		end
		error(`RobloxEnv: Instance.new("{className}") is not faked`, 2)
	end

	return {
		mount = mount,
		new = new,
		signal = signal,
		require = function(target: any): any
			const source = if type(target) == "table" then rawget(target, "__source") else nil
			if source == nil then
				return fallback(target)
			end
			const done = results[target]
			if done then
				return done.value
			end
			const value = load(source :: any, tostring(target.Name), target)
			results[target] = { value = value }
			return value
		end,
	}
end

return Instances
