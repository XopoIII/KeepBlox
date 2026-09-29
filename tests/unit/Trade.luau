--!strict
--- Trades between two profiles (DocumentService#127, findings #9): both or neither, whatever dies when.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, pets = {} }

const function give(amount: number): (a: any, b: any) -> ()
	return function(a: any, b: any)
		a.coins -= amount
		b.coins += amount
	end
end

-- Two players on server A with 500 and 0 coins.
const function setup(seed: number?): (World.World, World.Server, KeepBlox.Store, any, any)
	const world = World.new(seed or 21)
	const server = world:server({ name = "A", players = 2 })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = server.services })
	local a: any, b: any = nil, nil
	Sim.run(world.scheduler, "A", function()
		a = (store:load("u_a") :: any).profile
		b = (store:load("u_b") :: any).profile
		a.Data.coins = 500
		a:save()
	end, 10)
	return world, server, store, a, b
end

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

-- Loads both keys on a fresh server B and returns their coins.
const function reload(world: World.World): (number, number)
	const other = KeepBlox.store(
		"Profiles",
		{ template = TEMPLATE, services = world:server({ name = "B", players = 2 }).services }
	)
	local coinsA, coinsB = -1, -1
	Sim.run(world.scheduler, "B", function()
		const a = other:load("u_a")
		const b = other:load("u_b")
		assert(a.ok and b.ok, `reloaded ({(a :: any).reason}, {(b :: any).reason})`)
		coinsA, coinsB = a.profile.Data.coins, b.profile.Data.coins
		a.profile:release()
		b.profile:release()
	end, world.scheduler.now + 200)
	return coinsA, coinsB
end

Spec.test("Trade: both profiles change together, and the journals are cleared", function()
	const world, _, store, a, b = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:trade("u_a", "u_b", give(100)), { ok = true })
		Spec.equal(a.Data.coins, 400)
		Spec.equal(b.Data.coins, 100)
	end, world.scheduler.now + 30)
	Spec.equal(stored(world, "u_a").Data.coins, 400)
	Spec.equal(stored(world, "u_b").Data.coins, 100)
	Spec.equal(stored(world, "u_a").MetaData.KeepBlox.trade, nil)
	Spec.equal(stored(world, "u_b").MetaData.KeepBlox.trade, nil)
end)

Spec.test("Trade: a change that throws or cannot be stored changes nothing", function()
	const world, _, store, a, b = setup()
	Sim.run(world.scheduler, "A", function()
		const thrown = store:trade("u_a", "u_b", function(x: any)
			x.coins -= 100
			error("not enough", 0)
		end)
		Spec.equal(thrown, { ok = false, reason = "error", message = "not enough" })
		const refused = store:trade("u_a", "u_b", function(_: any, y: any)
			y.coins = 0 / 0
		end)
		Spec.equal(refused, { ok = false, reason = "refused", message = "dataB.coins: NaN cannot be stored" })
		Spec.equal({ a.Data.coins, b.Data.coins }, { 500, 0 })
	end, world.scheduler.now + 30)
	Spec.equal(world.backend:latest("Profiles__trades/global", "x"), nil)
end)

Spec.test("Trade: only profiles open on this server trade", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:trade("u_a", "u_z", give(1)), { ok = false, reason = "notHere" })
	end, world.scheduler.now + 5)
end)

Spec.test("Trade: a profile lost to another server aborts the trade; the other side is put back", function()
	const world, server, store, a, b = setup()
	const thief = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "C" }).services })
	Sim.run(world.scheduler, "C", function()
		assert((thief:load("u_b", { steal = true }) :: any).ok, "stolen")
	end, world.scheduler.now + 10)
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:trade("u_a", "u_b", give(100))
	end, world.scheduler.now + 60)
	Spec.equal(result.ok, false)
	Spec.equal(a.Data.coins, 500, "A back in memory")
	Spec.equal(stored(world, "u_a").Data.coins, 500, "A back in the store")
	Spec.equal(stored(world, "u_a").MetaData.KeepBlox.trade, nil)
	Spec.equal(b:isActive(), false)
	const _ = server
end)

Spec.test("Trade: two trades at once run one after the other, and coins are conserved", function()
	const world, _, store, a, b = setup()
	const results = {}
	Sim.run(world.scheduler, "A", function()
		for amount = 1, 5 do
			world.scheduler:spawn(function()
				table.insert(
					results,
					store:trade(
						if amount % 2 == 0 then "u_b" else "u_a",
						if amount % 2 == 0 then "u_a" else "u_b",
						give(amount)
					).ok
				)
			end, "A")
		end
	end, world.scheduler.now + 60)
	Spec.equal(results, { true, true, true, true, true })
	Spec.equal(a.Data.coins + b.Data.coins, 500)
	Spec.equal(stored(world, "u_a").Data.coins + stored(world, "u_b").Data.coins, 500)
end)

-- The server dies right after the n-th write of a trade; another server then loads both players.
for n = 1, 6 do
	Spec.test(`Trade: a server dying after write {n} of a trade leaves both or neither`, function()
		const world, server, store = setup(30 + n)
		local writes = 0
		world.backend:observe(function(event)
			if
				event.writer == "A"
				and (event.store == "Profiles__trades/global" or event.key == "u_a" or event.key == "u_b")
			then
				writes += 1
			end
		end)
		const before = writes
		world.scheduler:spawn(function()
			store:trade("u_a", "u_b", give(100))
		end, "A")
		-- Step the world one thread at a time until the n-th write has landed.
		local running = true
		while running and writes - before < n do
			running = world.scheduler:step()
		end
		server:crash()
		const coinsA, coinsB = reload(world)
		Spec.equal(coinsA + coinsB, 500, `coins conserved ({coinsA} + {coinsB})`)
		Spec.truthy(
			(coinsA == 400 and coinsB == 100) or (coinsA == 500 and coinsB == 0),
			`one outcome ({coinsA}, {coinsB})`
		)
		Spec.equal(stored(world, "u_a").MetaData.KeepBlox.trade, nil, "A's journal settled")
		Spec.equal(stored(world, "u_b").MetaData.KeepBlox.trade, nil, "B's journal settled")
	end)
end

Spec.test("Trade: 40 seeds of random store failures and a crash at a random moment never make or lose coins", function()
	for seed = 1, 40 do
		const world, server, store = setup(100 + seed)
		const random = world.scheduler.random
		for _ = 1, 3 do
			world.faults:add({
				op = "UpdateAsync",
				error = "502: API Services rejected request",
				times = random:integer(1, 2),
				after = random:chance(0.5),
			})
		end
		world.scheduler:spawn(function()
			for amount = 1, 3 do
				store:trade("u_a", "u_b", give(amount * 10))
			end
		end, "A")
		world.scheduler:run(world.scheduler.now + random:number() * 20)
		server:crash()
		world.faults:clear()
		const coinsA, coinsB = reload(world)
		Spec.equal(coinsA + coinsB, 500, `seed {seed}: {coinsA} + {coinsB}`)
	end
end)

Spec.test(
	"Trade: with the trade store down, the trade fails, both are put back, and a crash then keeps them so",
	function()
		const world, server, store, a, b = setup()
		world.faults:add({
			op = "UpdateAsync",
			key = "u_a",
			error = "502: API Services rejected request",
			times = 1,
			after = true,
		})
		local result: any = nil
		Sim.run(world.scheduler, "A", function()
			result = store:trade("u_a", "u_b", give(100))
		end, world.scheduler.now + 60)
		Spec.equal(result.ok, false)
		Spec.equal({ a.Data.coins, b.Data.coins }, { 500, 0 })
		-- Play goes on; a crash later must not roll that back to before the trade.
		Sim.run(world.scheduler, "A", function()
			a.Data.coins += 7
			Spec.equal(a:save(), true)
		end, world.scheduler.now + 30)
		server:crash()
		Spec.equal({ reload(world) }, { 507, 0 })
	end
)

Spec.test("Trade: a commit that landed but failed to answer is learnt on the retry", function()
	const world, _, store, a, b = setup()
	local tradeWrites = 0
	world.backend:observe(function(event)
		if event.store == "Profiles__trades/global" then
			tradeWrites += 1
			if tradeWrites == 2 then
				-- The commit landed; its answer is lost.
				world.faults:add({
					op = "UpdateAsync",
					key = event.key,
					error = "502: API Services rejected request",
					times = 1,
					after = true,
				})
			end
		end
	end)
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:trade("u_a", "u_b", give(100))
	end, world.scheduler.now + 60)
	Spec.equal(result, { ok = true })
	Spec.equal({ a.Data.coins, b.Data.coins }, { 400, 100 })
end)

return nil
