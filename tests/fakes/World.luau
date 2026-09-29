--!strict
--- A simulated Roblox: one scheduler, one data store backend and one message bus, shared by any number
--- of virtual servers. Each server gets its own `Services` bundle, clock, budget and data store caches,
--- and runs the real library code on them.
---
---     const world = World.new(seed)
---     const a = world:server({ name = "A", players = 10 })
---     a.services.clock.spawn(function() ... end)
---     world.scheduler:run()
const Backend = require("./Backend")
const Budget = require("./Budget")
const Clock = require("./Clock")
const DataStore = require("./DataStore")
const Faults = require("./Faults")
const Messaging = require("./Messaging")
const Ordered = require("./Ordered")
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

export type ServerOptions = {
	name: string,
	players: number?,
	skew: number?,
	drift: number?,
	placeId: number?,
	jobId: string?,
}

export type Server = {
	read name: string,
	read services: Services.Services,
	read budget: Budget.Budget,
	--> BindToClose callbacks registered on this server, in order.
	read closing: { () -> () },
	--> Stops the server where it stands: its threads are dropped and its subscriptions go dead.
	crash: (self: Server) -> (),
}

export type World = {
	read scheduler: Scheduler.Scheduler,
	read backend: Backend.Backend,
	read faults: Faults.Faults,
	read bus: Messaging.Bus,
	--> Every ordered data store's values, by store id ("<name>/<scope>").
	read ordered: Ordered.Shared,
	read epoch: number,
	server: (self: World, options: ServerOptions) -> Server,
}

const DEFAULT_EPOCH = 1_800_000_000
const DEFAULT_PLACE_ID = 1

const World = {}

function World.new(seed: number, epoch: number?): World
	const scheduler = Scheduler.new(seed)
	const faults = Faults.new(scheduler.random)
	const start = epoch or DEFAULT_EPOCH
	const names: { [string]: boolean } = {}

	const world: World = {
		scheduler = scheduler,
		backend = Backend.new(),
		faults = faults,
		bus = Messaging.bus(scheduler, faults, start),
		ordered = {},
		epoch = start,

		server = function(self: World, options: ServerOptions): Server
			const name = options.name
			assert(not names[name], `a server named {name} already exists`)
			names[name] = true

			const budget = Budget.new(scheduler, options.players)
			const context: DataStore.Context = {
				scheduler = scheduler,
				backend = self.backend,
				faults = faults,
				budget = budget,
				server = name,
				epoch = start,
			}
			const handles: { [string]: Services.DataStore } = {}
			const closing: { () -> () } = {}

			const dataStores = {}
			function dataStores.GetDataStore(
				_: Services.DataStoreService,
				store: string,
				scope: string?
			): Services.DataStore
				-- As in the engine, one name and scope give one handle, and so one cache, per server.
				const id = `{store}/{scope or "global"}`
				local handle = handles[id]
				if not handle then
					handle = DataStore.new(context, id)
					handles[id] = handle
				end
				return handle
			end
			const orderedHandles: { [string]: Services.OrderedDataStore } = {}
			function dataStores.GetOrderedDataStore(
				_: Services.DataStoreService,
				store: string,
				scope: string?
			): Services.OrderedDataStore
				const id = `{store}/{scope or "global"}`
				local handle = orderedHandles[id]
				if not handle then
					handle = Ordered.new({
						scheduler = scheduler,
						faults = faults,
						budget = budget,
						server = name,
						shared = self.ordered,
					}, id)
					orderedHandles[id] = handle
				end
				return handle
			end
			function dataStores.GetRequestBudgetForRequestType(
				_: Services.DataStoreService,
				requestType: Services.RequestType
			): number
				return budget:available(requestType)
			end

			return {
				name = name,
				budget = budget,
				closing = closing,
				services = {
					dataStores = dataStores :: Services.DataStoreService,
					messaging = self.bus:handle(name),
					clock = Clock.new(scheduler, {
						group = name,
						skew = options.skew,
						drift = options.drift,
						epoch = start,
					}),
					placeId = options.placeId or DEFAULT_PLACE_ID,
					jobId = options.jobId or `job-{name}`,
					isStudio = false,
					bindToClose = function(callback: () -> ())
						table.insert(closing, callback)
					end,
					guid = function(): string
						const random = scheduler.random
						return string.format(
							"%08X-%08X-%08X-%08X",
							random:nextU32(),
							random:nextU32(),
							random:nextU32(),
							random:nextU32()
						)
					end,
				},
				crash = function(_: Server)
					scheduler:crash(name)
					self.bus:disconnectServer(name)
				end,
			}
		end,
	}
	return world
end

return World
