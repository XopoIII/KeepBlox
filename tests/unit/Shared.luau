--!strict
--- Shared documents with no session lock, changed by any server (Lapis#58, DocumentService#89,
--- ProfileStore thread p3 #55-59).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { bank = 0, members = {} }

const function open(world: World.World, name: string): (KeepBlox.SharedStore, World.Server)
	const server = world:server({ name = name, players = 1 })
	return KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services }), server
end

Spec.test("Shared: updates from three servers at once all land", function()
	const world = World.new(4)
	const stores = {}
	for _, name in { "A", "B", "C" } do
		stores[name] = (open(world, name))
	end
	local failed = 0
	for name, store in stores do
		for _ = 1, 10 do
			world.scheduler:spawn(function()
				if not store:update("g_1", function(data: any)
					data.bank += 1
				end).ok then
					failed += 1
				end
			end, name)
		end
	end
	world.scheduler:run(world.scheduler.now + 300)
	Spec.equal(failed, 0)
	Spec.equal((world.backend:latest("Guilds/global", "g_1") :: any).value.Data.bank, 30)
end)

Spec.test("Shared: a missing document reads as the template; a failed change writes nothing", function()
	const world = World.new(4)
	const store = open(world, "A")
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:read("g_2"), { ok = true, data = TEMPLATE })
		Spec.equal(
			store:update("g_2", function(data: any)
				data.bank = 0 / 0
			end),
			{ ok = false, reason = "refused", message = "Data.bank: NaN cannot be stored" }
		)
		Spec.equal(
			store:update("g_2", function()
				error("no such member", 0)
			end),
			{ ok = false, reason = "error", message = "no such member" }
		)
	end, 60)
	Spec.equal(world.backend:latest("Guilds/global", "g_2"), nil)
end)

Spec.test("Shared: a profile's key is refused, so a session lock is never broken", function()
	const world = World.new(4)
	const server = world:server({ name = "A", players = 1 })
	const profiles = KeepBlox.store("Guilds", { template = TEMPLATE, services = server.services })
	const shared = KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services })
	Sim.run(world.scheduler, "A", function()
		assert((profiles:load("u_1") :: any).ok, "a profile holds the key")
		const result = shared:update("u_1", function(data: any)
			data.bank = 1
		end)
		Spec.equal(result.ok, false)
		Spec.equal((result :: any).reason, "locked")
	end, 30)
end)

Spec.test("Shared: watchers on other servers hear about each update", function()
	const world = World.new(4)
	const a = open(world, "A")
	const b = open(world, "B")
	local seen: any = nil
	Sim.run(world.scheduler, "B", function()
		b:watch("g_1", function(data: any)
			seen = data.bank
		end)
	end, 5)
	Sim.run(world.scheduler, "A", function()
		a:update("g_1", function(data: any)
			data.bank = 70
		end)
	end, world.scheduler.now + 10)
	Spec.equal(seen, 70)
end)

return nil
