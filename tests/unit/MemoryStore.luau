--!strict
--- The MemoryStore fake (tests/fakes/MemoryStore) against the documented behaviour.
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function setup(players: number?): (World.World, any)
	const world = World.new(2)
	const server = world:server({ name = "A", players = players or 1 })
	return world, server.memoryStores
end

Spec.test("MemoryStore: items expire; UpdateAsync returning nil changes nothing; zero expiration removes", function()
	const world, memory = setup()
	Sim.run(world.scheduler, "A", function()
		const map = memory:GetSortedMap("m")
		map:SetAsync("k", 1, 10)
		Spec.equal(map:GetAsync("k"), 1)
		Spec.equal(
			map:UpdateAsync("k", function(): any
				return nil
			end, 10),
			nil
		)
		Spec.equal(map:GetAsync("k"), 1)
		world.scheduler:wait(11)
		Spec.equal(map:GetAsync("k"), nil, "expired")
		map:SetAsync("k", 2, 10)
		map:UpdateAsync("k", function(value: any): any
			return value
		end, 0)
		Spec.equal(map:GetAsync("k"), nil, "a zero expiration")
	end)
end)

Spec.test("MemoryStore: a value over 32 KB, and the experience over its memory quota, are refused", function()
	const world, memory = setup(0)
	const caught = Sim.catch(world.scheduler, "A", function()
		memory:GetSortedMap("m"):SetAsync("big", string.rep("x", 33 * 1024), 60)
	end)
	Spec.truthy(caught ~= nil and string.find(caught, "ItemValueSizeTooLarge", 1, true) ~= nil, tostring(caught))
	const quota = Sim.catch(world.scheduler, "A", function()
		const map = memory:GetSortedMap("m")
		for index = 1, 10 do
			map:SetAsync(`k{index}`, string.rep("x", 30 * 1024), 60)
		end
	end)
	Spec.truthy(quota ~= nil and string.find(quota, "ExceededMemoryQuota", 1, true) ~= nil, tostring(quota))
end)

Spec.test("MemoryStore: a read queue item is hidden until removed or its invisibility ends", function()
	const world, memory = setup()
	Sim.run(world.scheduler, "A", function()
		const queue = memory:GetQueue("q", 5)
		queue:AddAsync("a", 60)
		queue:AddAsync("b", 60, 1)
		const first, id = queue:ReadAsync(1, false, 0)
		Spec.equal(first, { "b" }, "priority first")
		Spec.equal(queue:ReadAsync(5, false, 0), { "a" })
		world.scheduler:wait(6)
		const again = queue:ReadAsync(5, false, 0)
		Spec.equal(#again, 2, "both visible again")
		queue:RemoveAsync(id :: string)
	end)
end)

Spec.test("MemoryStore: the request units run out at 1000 + 120 per user a minute", function()
	const world, memory = setup(0)
	-- All within one minute.
	world.faults.latency = { min = 0, max = 0 }
	const caught = Sim.catch(world.scheduler, "A", function()
		const map = memory:GetSortedMap("m")
		for _ = 1, 1001 do
			map:GetAsync("k")
		end
	end)
	Spec.truthy(caught ~= nil and string.find(caught, "TotalRequestsOverLimit", 1, true) ~= nil, tostring(caught))
end)

return nil
