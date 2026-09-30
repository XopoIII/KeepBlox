--!strict
--- The fake DataStore under contention and failure: UpdateAsync's re-runs, budgets, queues, faults.
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

Spec.test("UpdateAsync: concurrent increments from two servers both land", function()
	for seed = 1, 25 do
		const world = World.new(seed)
		const scheduler = world.scheduler
		local runs = 0
		for _, name in { "A", "B" } do
			const store = world:server({ name = name }).services.dataStores:GetDataStore("P")
			scheduler:spawn(function()
				for _ = 1, 3 do
					store:UpdateAsync("k", function(current: number?): number
						runs += 1
						return (current or 0) + 1
					end)
				end
			end, name)
		end
		scheduler:run()
		Spec.equal(#scheduler.failures, 0, `seed {seed} failures`)
		Spec.equal((world.backend:latest("P/global", "k") :: any).value, 6, `seed {seed} total`)
		Spec.truthy(runs >= 6, `seed {seed}: at least one run per write`)
	end
end)

Spec.test("UpdateAsync: a conflicting write makes the transform run again on the new value", function()
	-- Across seeds, some interleaving must put B's write inside A's read-write window.
	local rerunSeen = false
	for seed = 1, 50 do
		const world = World.new(seed)
		const scheduler = world.scheduler
		const a = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
		const b = world:server({ name = "B" }).services.dataStores:GetDataStore("P")
		const seen: { string } = {}
		scheduler:spawn(function()
			a:UpdateAsync("k", function(current: any): string
				table.insert(seen, tostring(current))
				return "a"
			end)
		end, "A")
		scheduler:spawn(function()
			b:SetAsync("k", "b")
		end, "B")
		scheduler:run()
		if #seen == 2 then
			rerunSeen = true
			Spec.equal(seen, { "nil", "b" }, `seed {seed}`)
			Spec.equal((world.backend:latest("P/global", "k") :: any).value, "a")
		end
	end
	Spec.truthy(rerunSeen, "some seed in 1..50 produced a re-run")
end)

Spec.test("UpdateAsync: returning nil cancels the write and returns nil", function()
	const world = World.new(1)
	const store = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	Sim.run(world.scheduler, "A", function()
		store:SetAsync("k", 1)
		const value, info = store:UpdateAsync("k", function(): any
			return nil
		end)
		Spec.equal(value, nil)
		Spec.equal(info, nil)
	end)
	Spec.equal(#world.backend:versions("P/global", "k"), 1)
end)

Spec.test("UpdateAsync: userIds and metadata not returned are cleared", function()
	const world = World.new(1)
	const store = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	Sim.run(world.scheduler, "A", function()
		store:SetAsync("k", 1, { 11 }, { m = 1 })
		local seenIds = {}
		const _, info = store:UpdateAsync("k", function(current: number, keyInfo: any): number
			seenIds = keyInfo:GetUserIds()
			return current + 1
		end)
		Spec.equal(seenIds, { 11 })
		assert(info, "key info")
		Spec.equal(info:GetUserIds(), {})
		Spec.equal(info:GetMetadata(), {})
		const _, kept = store:UpdateAsync("k", function(current: number): (number, { number }, { [string]: any })
			return current + 1, { 11 }, { m = 2 }
		end)
		assert(kept, "key info")
		Spec.equal(kept:GetUserIds(), { 11 })
		Spec.equal(kept:GetMetadata(), { m = 2 })
	end)
end)

Spec.test("UpdateAsync: a transform that yields or throws fails the call and writes nothing", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const store = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	Sim.run(scheduler, "A", function()
		Spec.throws(function()
			store:UpdateAsync("k", function(): number
				coroutine.yield()
				return 1
			end)
		end, "cannot yield")
		Spec.throws(function()
			store:UpdateAsync("k", function(): number
				error("transform broke", 0)
			end)
		end, "transform broke")
	end)
	Spec.equal(#world.backend:versions("P/global", "k"), 0)
end)

-- The burst a new server starts with, as measured live (one player, 2026-09-30).
Spec.test("Budget: a new server starts with the live burst, and reads beyond it wait to refill", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	-- Ten players: the experience allows 700 reads a minute, so the server's own burst is what runs out.
	const server = world:server({ name = "A", players = 10 })
	const services = server.services
	const store = services.dataStores:GetDataStore("P")
	world.faults.latency = { min = 0, max = 0 }
	Spec.equal(services.dataStores:GetRequestBudgetForRequestType("StandardRead"), 600)
	Spec.equal(services.dataStores:GetRequestBudgetForRequestType("StandardWrite"), 600)
	Spec.equal(services.dataStores:GetRequestBudgetForRequestType("StandardList"), 35)
	Spec.equal(services.dataStores:GetRequestBudgetForRequestType("OrderedWrite"), 120)
	Spec.equal(services.dataStores:GetRequestBudgetForRequestType("OrderedList"), 35)
	Sim.run(scheduler, "A", function()
		for _ = 1, 600 do
			store:GetAsync("k", false)
		end
		Spec.equal(scheduler.now, 0)
		Spec.equal(services.dataStores:GetRequestBudgetForRequestType("StandardRead"), 0)
		store:GetAsync("k", false)
		-- 460 a minute: the next waits 60/460 of a second for a whole request.
		Spec.truthy(math.abs(scheduler.now - 60 / 460) < 1e-9, `waited {scheduler.now}`)
	end)
end)

Spec.test("Budget: going over the experience's limit is refused as unmodelled, whichever server asks", function()
	const world = World.new(1)
	world.faults.latency = { min = 0, max = 0 }
	const a = world:server({ name = "A", players = 1 }).services.dataStores:GetDataStore("P")
	const b = world:server({ name = "B", players = 1 }).services.dataStores:GetDataStore("P")
	-- Two users: 300 + 2 x 40 = 380 reads a minute for the whole experience.
	Sim.run(world.scheduler, "A", function()
		for _ = 1, 200 do
			a:GetAsync("k", false)
		end
	end)
	const caught = Sim.catch(world.scheduler, "B", function()
		for _ = 1, 181 do
			b:GetAsync("k", false)
		end
	end)
	Spec.truthy(
		caught ~= nil and string.find(caught, "UNMODELLED: StandardRead over the experience's 380", 1, true) ~= nil,
		tostring(caught)
	)
end)

Spec.test("Budget: more players, a faster refill, and nothing caps it", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 10, emptyBudget = true })
	const dataStores = server.services.dataStores
	Spec.equal(dataStores:GetRequestBudgetForRequestType("StandardWrite"), 0)
	const seen = {}
	Sim.run(world.scheduler, "A", function()
		world.scheduler:wait(60)
		seen.write, seen.list =
			dataStores:GetRequestBudgetForRequestType("StandardWrite"),
			dataStores:GetRequestBudgetForRequestType("StandardList")
		world.scheduler:wait(17 * 60)
		seen.later = dataStores:GetRequestBudgetForRequestType("StandardWrite")
	end, 18 * 60 + 1)
	Spec.equal(seen, { write = 460, list = 25, later = 18 * 460 })
end)

Spec.test("Budget: the 31st waiting request fails with 301 at once", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const store = world:server({ name = "A", players = 0, emptyBudget = true }).services.dataStores:GetDataStore("P")
	world.faults.latency = { min = 0, max = 0 }
	const errors: { string } = {}
	for _ = 1, 31 do
		scheduler:spawn(function()
			const ok, message = pcall(store.GetAsync, store, "k", false)
			if not ok then
				table.insert(errors, tostring(message))
			end
		end, "A")
	end
	scheduler:run()
	Spec.equal(#errors, 1)
	Spec.truthy(string.find(errors[1], "301: GetAsync request dropped", 1, true) ~= nil, errors[1])
end)

Spec.test("Faults: an error before the write leaves the store untouched", function()
	const world = World.new(1)
	const store = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	world.faults:add({ op = "SetAsync", key = "k", error = "502: rejected", times = 1 })
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			store:SetAsync("k", 1)
		end, "502: rejected")
		Spec.equal(#world.backend:versions("P/global", "k"), 0)
		store:SetAsync("k", 2)
		Spec.equal(store:GetAsync("k", false), 2)
	end)
end)

Spec.test("Faults: an error after the write still wrote (the call failed, the data did not)", function()
	const world = World.new(1)
	const store = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	world.faults:add({ op = "UpdateAsync", error = "502: lost reply", after = true, times = 1 })
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			store:UpdateAsync("k", function(): number
				return 7
			end)
		end, "502: lost reply")
		Spec.equal(store:GetAsync("k", false), 7)
	end)
end)

Spec.test("Faults: a hung call never returns; other servers carry on", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const a = world:server({ name = "A" }).services.dataStores:GetDataStore("P")
	const b = world:server({ name = "B" }).services.dataStores:GetDataStore("P")
	world.faults:add({ op = "GetAsync", server = "A", hang = true })
	local returned = false
	scheduler:spawn(function()
		a:GetAsync("k")
		returned = true
	end, "A")
	Sim.run(scheduler, "B", function()
		b:SetAsync("k", 1)
	end)
	Spec.equal(returned, false)
	Spec.equal(scheduler:count("A"), 1)
end)

return nil
