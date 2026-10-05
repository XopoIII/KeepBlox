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

-- A place file never published: the engine refuses the data store itself, before any call on it
-- (DataStoreService:GetDataStore throws this message there).
const UNPUBLISHED = "You must publish this place to the web to access DataStore."
const UNPUBLISHED_NOTICE = "This place is not published: profiles are kept in memory, and nothing is saved"

const function unpublished(world: World.World, name: string, isStudio: boolean): any
	const services: any = table.clone(world:server({ name = name }).services)
	services.isStudio = isStudio
	services.dataStores = table.clone(services.dataStores)
	services.dataStores.GetDataStore = function()
		error(UNPUBLISHED, 0)
	end
	return services
end

for _, mode in { "live", "copy" } do
	Spec.test(`Mock: Studio in a place never published opens in memory and says so once (studio = {mode})`, function()
		const world = World.new(1)
		const seen = writes(world)
		const store = KeepBlox.store("Profiles", {
			template = { coins = 0 },
			services = unpublished(world, "A", true),
			studio = mode :: any,
		})
		const errors: { string } = {}
		store.onError:connect(function(key: string, message: string)
			table.insert(errors, `{key}|{message}`)
		end)
		Sim.run(world.scheduler, "A", function()
			const result = store:load("u_1")
			assert(result.ok, "loaded in memory")
			result.profile.Data.coins = 3
			Spec.equal(result.profile:save(), true)
			result.profile:release()
			const again = store:load("u_1")
			assert(again.ok, "loaded again")
			Spec.equal(again.profile.Data.coins, 3, "memory keeps the play test's data")
			again.profile:release()
		end, 60)
		Spec.equal(errors, { `|{UNPUBLISHED_NOTICE}` })
		Spec.equal(seen, {})
	end)
end

Spec.test("Mock: a live server that cannot get its data store still fails, whatever the message", function()
	const world = World.new(1)
	Spec.throws(function()
		KeepBlox.store("Profiles", { template = { coins = 0 }, services = unpublished(world, "A", false) })
	end, UNPUBLISHED)
end)

Spec.test("Mock: Studio fails on a data store error that is not about access", function()
	const world = World.new(1)
	const services = unpublished(world, "A", true)
	services.dataStores.GetDataStore = function()
		error("DataStore name is too long", 0)
	end
	Spec.throws(function()
		KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	end, "DataStore name is too long")
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

Spec.test("Mock: studio = memory never touches live data, even with API access (ProfileStore p6 #113)", function()
	const world = World.new(1)
	const seen = writes(world)
	const services: any = world:server({ name = "A" }).services
	services.isStudio = true
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services, studio = "memory" })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 5
		result.profile:release()
	end, 60)
	Spec.equal(seen, {})
end)

Spec.test("Mock: studio = copy starts from the live data, unlocked, and never writes it back", function()
	const world = World.new(1)
	const live =
		KeepBlox.store("Profiles", { template = { coins = 0 }, services = world:server({ name = "L" }).services })
	Sim.run(world.scheduler, "L", function()
		const result = live:load("u_1")
		assert(result.ok, "live load")
		result.profile.Data.coins = 42
		result.profile:save()
	end, 10)
	const byStudio: { string } = {}
	world.backend:observe(function(event)
		if event.writer == "S" then
			table.insert(byStudio, `{event.store} {event.key}`)
		end
	end)
	const services: any = world:server({ name = "S" }).services
	services.isStudio = true
	const studio = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services, studio = "copy" })
	local took = math.huge
	Sim.run(world.scheduler, "S", function()
		const started = world.scheduler.now
		const result = studio:load("u_1")
		assert(result.ok, "studio load")
		took = world.scheduler.now - started
		Spec.equal(result.profile.Data.coins, 42)
		result.profile.Data.coins = 0
		result.profile:release()
	end, world.scheduler.now + 30)
	Spec.truthy(took < 2, `the live owner was not waited on ({took} s)`)
	Spec.equal(byStudio, {}, "studio writes")
	Spec.equal((world.backend:latest("Profiles/global", "u_1") :: any).value.Data.coins, 42)
end)

Spec.test("Mock: a test can close a store as a shutdown would (DocumentService#80)", function()
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services, mock = "close" })
	const reasons: { string } = {}
	Sim.run(world.scheduler, "A", function()
		for index = 1, 3 do
			const result = store:load(`u_{index}`)
			assert(result.ok, "loaded")
			result.profile.Data.coins = index
			result.profile.onEnded:connect(function(reason: string)
				table.insert(reasons, reason)
			end)
		end
		store:close()
		Spec.equal(next(store:profiles()), nil, "every profile released")
		Spec.equal(store:load("u_9"), { ok = false, reason = "closing" })
	end, 60)
	Spec.equal(reasons, { "shutdown", "shutdown", "shutdown" })
	const again = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services, mock = "close" })
	Sim.run(world.scheduler, "A", function()
		Spec.equal((again:load("u_2") :: any).profile.Data.coins, 2, "saved on close")
	end, world.scheduler.now + 30)
end)

Spec.test("Mock: a studio mode other than live, memory or copy is refused", function()
	Spec.throws(function()
		KeepBlox.store("P", { template = {}, studio = "off" :: any })
	end, `studio is "live", "memory" or "copy", not "off"`)
end)

return nil
