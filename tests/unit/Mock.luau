--!strict
--- Profiles kept in memory: on request (scratch sets), and on their own in Studio without API access.
--- Either way, no live key is ever written: the access check only reads.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function writes(world: World.World): { string }
	const seen = {}
	world.backend:observe(function(event)
		table.insert(seen, `{event.store} {event.key}`)
	end)
	return seen
end

Spec.test("Mock: a scratch store works fully and never touches the data store", function()
	const world = World.new(1)
	const seen = writes(world)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services, mock = true })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 4
		Spec.equal(result.profile:save(), true)
		result.profile:release()
		const again = store:load("u_1")
		assert(again.ok, "loaded again")
		Spec.equal(again.profile.Data.coins, 4)
		again.profile:release()
	end, 60)
	Spec.equal(seen, {})
end)

Spec.test("Mock: scratch sets with different names do not see each other", function()
	const world = World.new(1)
	const services = world:server({ name = "A" }).services
	const first = KeepBlox.store("P", { template = { n = 0 }, services = services, mock = "first" })
	const second = KeepBlox.store("P", { template = { n = 0 }, services = services, mock = "second" })
	Sim.run(world.scheduler, "A", function()
		const a = first:load("k")
		assert(a.ok, "first")
		a.profile.Data.n = 1
		a.profile:release()
		const b = second:load("k")
		assert(b.ok, "second")
		Spec.equal(b.profile.Data.n, 0)
		b.profile:release()
	end, 60)
end)

Spec.test("Mock: Studio without API access falls back to memory after a read-only check", function()
	const world = World.new(1)
	const seen = writes(world)
	const server = world:server({ name = "A" })
	const services: any = server.services
	services.isStudio = true
	world.faults:add({ error = "403: Cannot write to DataStore from studio if API access is not enabled." })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	const errors: { string } = {}
	store.onError:connect(function(_: string, message: string)
		table.insert(errors, message)
	end)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded in memory")
		result.profile:release()
	end, 60)
	Spec.equal(errors, { "Studio has no API access: profiles are kept in memory, and nothing is saved" })
	Spec.equal(seen, {})
end)

Spec.test("Mock: Studio with API access uses the real store", function()
	const world = World.new(1)
	const seen = writes(world)
	const services: any = world:server({ name = "A" }).services
	services.isStudio = true
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile:release()
	end, 60)
	Spec.equal(seen[1], "Profiles/global u_1")
end)

return nil
