--!strict
--- The engine globals one virtual server gives the Roblox code it runs: `game`, `task`, `os`,
--- `coroutine`, `Enum`, `Instance`, `DateTime`, `typeof`, `require`, `script`, `warn` and `print`, all over
--- the fakes (see env/Engine, env/Instances, env/Services).
---
--- This is how unmodified Roblox modules (the vendored ProfileStore, the rival libraries the benchmarks
--- download) run in the simulator. Each server loads its own copy of a module into its own
--- environment, so module state is per server, as it is in Roblox.
const Engine = require("./env/Engine")
const Instances = require("./env/Instances")
const ServicesEnv = require("./env/Services")
const World = require("@fakes/World")
const fs = require("@lune/fs")
const luau = require("@lune/luau")

export type Node = Instances.Node

export type Env = {
	read server: World.Server,
	read globals: { [string]: any },
	--> Everything the code printed or warned, in order.
	read log: { string },
	--> Players joining and leaving this server.
	read players: ServicesEnv.Players,
	--> Runs a module's `source` in this server's environment, and returns what it returns. It must be
	--> called from a thread of this server. Read the source first, outside any simulated thread, with
	--> `RobloxEnv.read`.
	load: (self: Env, source: string, name: string) -> any,
	--> Calls `observer(store, key, value)` after each write this server makes commits: what a library
	--> was told is stored. Adapters of libraries with no save signal acknowledge through it.
	onWrite: (self: Env, observer: ServicesEnv.WriteObserver) -> (),
	--> Builds a module tree read with `RobloxEnv.tree` as instances, and returns its root, for `require`.
	mount: (self: Env, node: Node, parent: any?) -> any,
}

export type Options = {
	frame: number?,
	isStudio: boolean?,
}

const RobloxEnv = {}

function RobloxEnv.new(world: World.World, server: World.Server, options: Options?): Env
	const services = server.services
	const frame = if options and options.frame then options.frame else 0.1
	const engine = Engine.new(world, server, frame, options ~= nil and options.isStudio == true)
	const log: { string } = {}

	const function line(...: any): string
		const parts = table.pack(...)
		const words = {}
		for index = 1, parts.n do
			words[index] = tostring(parts[index])
		end
		return table.concat(words, " ")
	end

	const globals: { [string]: any } = {}
	const function run(source: string, name: string, script: any): any
		const env = table.clone(globals)
		env.script = script
		const chunk = luau.load(source, { debugName = name, environment = env })
		return chunk()
	end
	const instances = Instances.new(engine, run, function(target: any): any
		error(`RobloxEnv: cannot require {tostring(target)}`, 2)
	end)
	const observers: { ServicesEnv.WriteObserver } = {}
	const byName, players = ServicesEnv.build(world, server, engine, instances, observers)

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
	for name, service in byName do
		(game :: any)[name] = service
	end

	globals.game = game
	globals.task = engine.task
	globals.os = engine.os
	globals.coroutine = engine.coroutine
	globals.Enum = engine.Enum
	globals.DateTime = engine.DateTime
	globals.typeof = engine.typeof
	globals.require = instances.require
	globals.Instance = { new = instances.new }
	globals.warn = function(...: any)
		table.insert(log, "warn: " .. line(...))
	end
	globals.print = function(...: any)
		table.insert(log, line(...))
	end
	globals.wait = engine.wait
	globals.spawn = function(fn: (...any) -> ())
		engine.task.defer(fn)
	end

	return {
		server = server,
		globals = globals,
		log = log,
		players = players,
		load = function(_: Env, source: string, name: string): any
			return run(source, name, { Name = name })
		end,
		onWrite = function(_: Env, observer: ServicesEnv.WriteObserver)
			table.insert(observers, observer)
		end,
		mount = function(_: Env, node: Node, parent: any?): any
			return instances.mount(node, parent)
		end,
	}
end

--> A module's source text. Call it outside simulated threads: Lune's file functions yield to Lune's
--> own scheduler, and a simulated thread that yields there is resumed outside the simulation.
function RobloxEnv.read(path: string): string
	return fs.readFile(path)
end

--> A directory as a module tree (see Instances.Node), named `name`. Call it outside simulated threads.
function RobloxEnv.tree(path: string, name: string): Node
	const node: Node = { name = name, source = nil, children = {} }
	for _, entry in fs.readDir(path) do
		const full = `{path}/{entry}`
		if fs.isDir(full) then
			table.insert(node.children, RobloxEnv.tree(full, entry))
		else
			const stem, extension = string.match(entry, "^(.-)%.(luau?)$")
			if stem and extension and not string.find(entry, "%.spec%.") and not string.find(entry, "%.test%.") then
				if stem == "init" then
					node.source = fs.readFile(full)
				else
					table.insert(node.children, { name = stem, source = fs.readFile(full), children = {} })
				end
			end
		end
	end
	table.sort(node.children, function(a: Node, b: Node): boolean
		return a.name < b.name
	end)
	return node
end

return RobloxEnv
