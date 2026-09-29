--!strict
--- The public API, one behaviour at a time, on a simulated server.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, items = {} }

const function setup(seed: number?): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(seed or 1)
	const server = world:server({ name = "A", players = 1 })
	-- These specs exercise the renewal itself, so it runs every 15 s instead of the default 300.
	const store = KeepBlox.store(
		"Profiles",
		{ template = TEMPLATE, services = server.services, config = { renew = 15, death = 35 } }
	)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	return world, server, store, errors
end

const function stored(world: World.World, key: string): any
	const latest = world.backend:latest("Profiles/global", key)
	return if latest then latest.value else nil
end

Spec.test("Store: load, change, save, release", function()
	const world, _, store = setup()
	local ended: string? = nil
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		Spec.equal(profile.Data, { coins = 0, items = {} })
		Spec.equal(profile.loadCount, 1)
		profile.onEnded:connect(function(reason: string)
			ended = reason
		end)
		profile.Data.coins = 5
		Spec.equal(profile:save(), true)
		Spec.equal(stored(world, "u_1").Data.coins, 5)
		Spec.equal(profile.LastSavedData.coins, 5)
		profile.Data.coins = 9
		profile:release()
		Spec.equal(profile:isActive(), false)
	end, 60)
	Spec.equal(ended, "released")
	const record = stored(world, "u_1")
	Spec.equal(record.Data.coins, 9)
	Spec.equal(record.MetaData.ActiveSession, nil)
end)

Spec.test("Store: after the session ends, its data is frozen", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile:release()
		Spec.throws(function()
			result.profile.Data.coins = 1
		end, "readonly")
	end, 60)
end)

Spec.test("Store: unchanged data is not written again; changed data is, on the renewal", function()
	const world, _, store = setup()
	local profile: any = nil
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		profile = result.profile
	end, 1)
	const writesAfterLoad = #world.backend:versions("Profiles/global", "u_1")
	world.scheduler:run(world.scheduler.now + 40)
	const renewed = stored(world, "u_1")
	Spec.equal(renewed.Data.coins, 0)
	Spec.truthy(renewed.MetaData.KeepBlox.lease >= 3, `the lease was renewed ({renewed.MetaData.KeepBlox.lease})`)
	profile.Data.coins = 42
	world.scheduler:run(world.scheduler.now + 20)
	Spec.equal(stored(world, "u_1").Data.coins, 42)
	Spec.equal(writesAfterLoad, 1)
end)

Spec.test("Store: bad data is refused with its path, and the release still goes through", function()
	const world, _, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		profile.Data.coins = 3
		Spec.equal(profile:save(), true)
		profile.Data.items = { { name = "\xFF" } }
		Spec.equal(profile:save(), true, "the lease still renews")
		profile:release()
	end, 60)
	Spec.equal(errors, { "u_1: not saved: Data.items[1].name: string is not valid UTF-8" })
	const record = stored(world, "u_1")
	Spec.equal(record.Data, { coins = 3, items = {} })
	Spec.equal(record.MetaData.ActiveSession, nil)
end)

Spec.test("Store: one key opens once per server", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.truthy((store:load("u_1") :: any).ok, "first")
		Spec.equal(store:load("u_1"), { ok = false, reason = "open" })
	end, 5)
end)

Spec.test("Store: a cancelled load gives the key back", function()
	const world, _, store = setup()
	const other = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	Sim.run(world.scheduler, "B", function()
		assert((other:load("u_1") :: any).ok, "B holds it")
	end, 5)
	world.bus.partitioned.B = true
	local cancel = false
	local outcome: any = nil
	world.scheduler:spawn(function()
		outcome = store:load("u_1", {
			cancel = function(): boolean
				return cancel
			end,
		})
	end, "A")
	world.scheduler:run(world.scheduler.now + 3)
	cancel = true
	world.scheduler:run(world.scheduler.now + 30)
	Spec.equal(outcome, { ok = false, reason = "cancelled" })
end)

Spec.test("Store: a value that is not a profile is quarantined, never overwritten", function()
	const world, server, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		server.services.dataStores:GetDataStore("Profiles"):SetAsync("u_1", "legacy string")
		Spec.equal(store:load("u_1"), { ok = false, reason = "foreign" })
	end, 30)
	Spec.equal(stored(world, "u_1"), "legacy string")
	Spec.equal((world.backend:latest("Profiles__quarantine/global", "u_1") :: any).value.value, "legacy string")
	Spec.equal(#errors, 1)
end)

Spec.test("Store: a load that cannot finish fails with a timeout instead of hanging", function()
	const world, _, store = setup()
	world.faults:add({ op = "UpdateAsync", hang = true })
	local outcome: any = nil
	world.scheduler:spawn(function()
		outcome = store:load("u_1")
	end, "A")
	world.scheduler:run(200)
	Spec.equal(outcome, { ok = false, reason = "timeout" })
end)

Spec.test("Store: shutdown releases every profile in parallel", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		for index = 1, 20 do
			assert((store:load(`u_{index}`) :: any).ok, "loaded")
		end
	end, 10)
	world.faults.latency = { min = 2, max = 2 }
	local took = math.huge
	Sim.run(world.scheduler, "A", function()
		const started = world.scheduler.now
		for _, callback in server.closing do
			callback()
		end
		took = world.scheduler.now - started
	end)
	-- One call takes 2 s; twenty in parallel finish in one call's time, plus the 0.1 s polling step.
	Spec.truthy(took <= 2.2, `took {took} s`)
	for index = 1, 20 do
		Spec.equal(stored(world, `u_{index}`).MetaData.ActiveSession, nil, `u_{index} released`)
	end
end)

Spec.test("Store: a bad setup is refused", function()
	Spec.throws(function()
		KeepBlox.store("", { template = {} })
	end, "a store needs a name")
	Spec.throws(function()
		KeepBlox.store("P", { template = { bad = 0 / 0 } })
	end, "the template must be storable")
	Spec.throws(function()
		KeepBlox.store("P", { template = {}, config = { renew = 20, death = 30 } })
	end, "death must be at least twice renew")
end)

return nil
