--!strict
--- Purchases: granted once, never lost, and reported granted only once stored (guarantee 9).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const PRODUCTS = {
	[1] = function(profile: any)
		profile.Data.coins += 100
	end,
}

const function receipt(id: string): any
	return { PlayerId = 7, PurchaseId = id, ProductId = 1 }
end

const function setup(seed: number?): (World.World, World.Server, KeepBlox.Store, (any) -> string, { string })
	const world = World.new(seed or 1)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	const errors = {}
	store.onError:connect(function(_: string, message: string)
		table.insert(errors, message)
	end)
	const decide = store:receipts({
		keyFor = function(userId: number): string
			return `u_{userId}`
		end,
		products = PRODUCTS,
	})
	return world, server, store, decide, errors
end

const function stored(world: World.World): any
	return (world.backend:latest("Profiles/global", "u_7") :: any).value
end

Spec.test("Receipts: granted into the data, stored with its id, then reported granted", function()
	const world, _, store, decide = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(decide(receipt("r1")), "NotProcessedYet", "no session yet")
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		Spec.equal(decide(receipt("r1")), "PurchaseGranted")
		Spec.equal(stored(world).Data.coins, 100)
		Spec.equal(stored(world).MetaData.KeepBlox.receipts, { "r1" })
		Spec.equal(decide(receipt("r1")), "PurchaseGranted", "asked again")
		Spec.equal(result.profile.Data.coins, 100, "not granted twice")
		result.profile:release()
	end, 30)
end)

Spec.test("Receipts: a failed save is not reported granted, and the retry does not grant again", function()
	const world, _, store, decide = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		world.faults:add({ op = "UpdateAsync", error = "502: down" })
		Spec.equal(decide(receipt("r1")), "NotProcessedYet")
		Spec.equal(result.profile.Data.coins, 100)
		world.faults:clear()
		Spec.equal(decide(receipt("r1")), "PurchaseGranted")
		Spec.equal(result.profile.Data.coins, 100)
		Spec.equal(stored(world).Data.coins, 100)
		result.profile:release()
	end, 60)
end)

Spec.test("Receipts: a crash before the save loses the grant with its id; the next session grants once", function()
	const world, server, store, decide = setup(2)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		world.faults:add({ op = "UpdateAsync", server = "A", hang = true })
		world.scheduler:spawn(function()
			decide(receipt("r1"))
		end, "A")
	end, 2)
	server:crash()
	world.faults:clear()
	Spec.equal(stored(world).Data.coins, 0)
	const b = world:server({ name = "B" })
	const storeB = KeepBlox.store("Profiles", { template = { coins = 0 }, services = b.services })
	const decideB = storeB:receipts({
		keyFor = function(userId: number): string
			return `u_{userId}`
		end,
		products = PRODUCTS,
	})
	Sim.run(world.scheduler, "B", function()
		const result = storeB:load("u_7")
		assert(result.ok, "taken over")
		Spec.equal(decideB(receipt("r1")), "PurchaseGranted")
		result.profile:release()
	end, world.scheduler.now + 120)
	Spec.equal(stored(world).Data.coins, 100)
end)

Spec.test("Receipts: data that cannot be stored means the purchase is not granted", function()
	const world, _, store, decide, errors = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		result.profile.Data.bad = 0 / 0
		Spec.equal(decide(receipt("r1")), "NotProcessedYet")
		Spec.equal(stored(world).Data.coins, 0)
		result.profile.Data.bad = nil
		Spec.equal(decide(receipt("r1")), "PurchaseGranted")
		Spec.equal(stored(world).Data.coins, 100)
		result.profile:release()
	end, 60)
	Spec.equal(errors[1], "not saved: Data.bad: NaN cannot be stored")
end)

Spec.test("Receipts: an unknown product is not granted, and says why", function()
	const world, _, store, decide, errors = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		Spec.equal(decide({ PlayerId = 7, PurchaseId = "r9", ProductId = 99 }), "NotProcessedYet")
		result.profile:release()
	end, 30)
	Spec.equal(errors, { "no grant for product 99" })
end)

Spec.test("Receipts: the history keeps the newest ids only", function()
	const world, server = setup()
	const store = KeepBlox.store("Short", { template = { coins = 0 }, services = server.services })
	const decide = store:receipts({
		keyFor = function(userId: number): string
			return `u_{userId}`
		end,
		products = PRODUCTS,
		history = 2,
	})
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		for _, id in { "r1", "r2", "r3" } do
			Spec.equal(decide(receipt(id)), "PurchaseGranted")
		end
		Spec.equal(result.profile.Data.coins, 300)
		Spec.equal(
			(world.backend:latest("Short/global", "u_7") :: any).value.MetaData.KeepBlox.receipts,
			{ "r2", "r3" }
		)
		result.profile:release()
	end, 30)
end)

return nil
