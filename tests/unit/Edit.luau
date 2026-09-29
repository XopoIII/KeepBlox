--!strict
--- `store:edit`: support and admin edits that never kick a player (ProfileService#48, ProfileService
--- p40 #834, DocumentService#58).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

const function stored(world: World.World, key: string): any
	const latest = world.backend:latest("Profiles/global", key)
	return if latest then latest.value else nil
end

const function writes(world: World.World, key: string): number
	return #world.backend:versions("Profiles/global", key)
end

const function setup(): (World.World, KeepBlox.Store, World.Server)
	const world = World.new(3)
	const server = world:server({ name = "A", players = 1 })
	return world, KeepBlox.store("Profiles", { template = TEMPLATE, services = server.services }), server
end

const function grant(amount: number): (data: any) -> ()
	return function(data: any)
		data.coins += amount
	end
end

Spec.test("Edit: an offline key is claimed, edited and released", function()
	const world, store = setup()
	Sim.run(world.scheduler, "A", function()
		const first = store:load("u_1")
		assert(first.ok, "loaded")
		first.profile.Data.coins = 10
		first.profile:release()
		Spec.equal(store:edit("u_1", grant(5)), { ok = true, data = { coins = 15 } })
	end, 120)
	const record = stored(world, "u_1")
	Spec.equal(record.Data.coins, 15)
	Spec.equal(record.MetaData.ActiveSession, nil)
	Spec.equal(record.MetaData.SessionLoadCount, 2)
end)

Spec.test("Edit: a key that was never played starts from the template", function()
	const world, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:edit("u_9", grant(100)), { ok = true, data = { coins = 100 } })
	end, 60)
	Spec.equal(stored(world, "u_9").Data.coins, 100)
end)

Spec.test("Edit: a profile open on this server is edited in place and saved", function()
	const world, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(store:edit("u_1", grant(3)), { ok = true, data = { coins = 3 } })
		Spec.equal(result.profile.Data.coins, 3)
		Spec.equal(result.profile:isActive(), true)
	end, 60)
	Spec.equal(stored(world, "u_1").Data.coins, 3)
end)

Spec.test("Edit: a key a live server holds is left alone, and its player is not kicked", function()
	const world, store = setup()
	const other = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	local owner: any = nil
	Sim.run(world.scheduler, "B", function()
		const result = other:load("u_1")
		assert(result.ok, "B holds it")
		owner = result.profile
	end, 5)
	local outcome: any = nil
	local took = 0
	Sim.run(world.scheduler, "A", function()
		const started = world.scheduler.now
		outcome = store:edit("u_1", grant(1))
		took = world.scheduler.now - started
	end, world.scheduler.now + 120)
	Spec.equal(outcome, { ok = false, reason = "inUse" })
	Spec.truthy(took < 30, `answered in {took} s`)
	Spec.equal(owner:isActive(), true, "the owner keeps the key")
	Spec.equal(stored(world, "u_1").MetaData.ForceLoadSession, nil, "no hand-over was asked")
	Spec.equal(stored(world, "u_1").Data.coins, 0)
end)

Spec.test("Edit: a key held by a crashed server is taken once its lease stops", function()
	const world, store = setup()
	const serverB = world:server({ name = "B" })
	const other = KeepBlox.store("Profiles", { template = TEMPLATE, services = serverB.services })
	Sim.run(world.scheduler, "B", function()
		assert((other:load("u_1") :: any).ok, "B holds it")
	end, 5)
	serverB:crash()
	local outcome: any = nil
	Sim.run(world.scheduler, "A", function()
		outcome = store:edit("u_1", grant(2))
	end, world.scheduler.now + 200)
	Spec.equal(outcome, { ok = true, data = { coins = 2 } })
	Spec.equal(stored(world, "u_1").MetaData.ActiveSession, nil)
end)

Spec.test("Edit: an edit that throws writes nothing and leaves the live data as it was", function()
	const world, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const before = writes(world, "u_1")
		const outcome = store:edit("u_1", function(data: any)
			data.coins = 50
			error("no such item")
		end)
		Spec.equal(outcome.ok, false)
		Spec.equal((outcome :: any).reason, "error")
		Spec.truthy(string.find((outcome :: any).message, "no such item", 1, true) ~= nil, (outcome :: any).message)
		Spec.equal(result.profile.Data, { coins = 0 })
		Spec.equal(writes(world, "u_1"), before)
	end, 60)
end)

Spec.test("Edit: an edit that cannot be stored is refused with its path; the offline key is unchanged", function()
	const world, store = setup()
	local outcome: any = nil
	Sim.run(world.scheduler, "A", function()
		assert(store:edit("u_1", grant(4)).ok, "first edit")
		outcome = store:edit("u_1", function(data: any)
			data.coins = 0 / 0
		end)
	end, 120)
	Spec.equal(outcome, { ok = false, reason = "refused", message = "Data.coins: NaN cannot be stored" })
	Spec.equal(stored(world, "u_1").Data.coins, 4)
	Spec.equal(stored(world, "u_1").MetaData.ActiveSession, nil)
end)

return nil
