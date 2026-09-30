--!strict
--- The ordered data store fake (tests/fakes/Ordered) against the documented behaviour, and the
--- in-memory one mock stores use (src/MockOrdered).
const MockOrdered = require("@keepblox/MockOrdered")
const Services = require("@keepblox/Services")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function keys(entries: { Services.SortedEntry }): { string }
	const out = {}
	for _, entry in entries do
		table.insert(out, `{entry.key}={entry.value}`)
	end
	return out
end

const function fill(store: Services.OrderedDataStore)
	for index, value in { 30, 10, 50, 20, 40 } do
		store:SetAsync(`k{index}`, value)
	end
end

const function checkSorted(store: Services.OrderedDataStore)
	const descending = store:GetSortedAsync(false, 2)
	Spec.equal(keys(descending:GetCurrentPage()), { "k3=50", "k5=40" })
	Spec.equal(descending.IsFinished, false)
	descending:AdvanceToNextPageAsync()
	Spec.equal(keys(descending:GetCurrentPage()), { "k1=30", "k4=20" })
	descending:AdvanceToNextPageAsync()
	Spec.equal(keys(descending:GetCurrentPage()), { "k2=10" })
	Spec.equal(descending.IsFinished, true)
	Spec.equal(keys(store:GetSortedAsync(true, 10, 20, 40):GetCurrentPage()), { "k4=20", "k1=30", "k5=40" })
	Spec.equal(
		store:UpdateAsync("k2", function(current: number?): number?
			return (current or 0) + 5
		end),
		15
	)
	Spec.equal(store:RemoveAsync("k3"), 50)
	Spec.equal(store:GetAsync("k3"), nil)
end

Spec.test("Ordered: pages come sorted, bounded by value, and advance until finished", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	Sim.run(world.scheduler, "A", function()
		const store = server.services.dataStores:GetOrderedDataStore("Board")
		fill(store)
		checkSorted(store)
	end)
end)

-- Live (2026-09-30) six keys at one value came back x,c,a,b,m,q, and ascending q,m,b,a,c,x.
Spec.test("Ordered: ties come in a fixed order that is not by key, ascending the reverse", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	Sim.run(world.scheduler, "A", function()
		const store = server.services.dataStores:GetOrderedDataStore("Board")
		for _, key in { "m", "b", "x", "a", "q", "c" } do
			store:SetAsync(key, 5)
		end
		const order = function(ascending: boolean): { string }
			const found = {}
			for _, entry in store:GetSortedAsync(ascending, 10):GetCurrentPage() do
				table.insert(found, entry.key)
			end
			return found
		end
		const descending = order(false)
		Spec.equal(order(false), descending, "the same each time")
		const reversed = {}
		for index = #descending, 1, -1 do
			table.insert(reversed, descending[index])
		end
		Spec.equal(order(true), reversed)
		Spec.truthy(table.concat(descending) ~= "abcmqx" and table.concat(descending) ~= "xqmcba", "not by key")
	end)
end)

Spec.test("Ordered: every server sees one store, and each call draws its own budget", function()
	const world = World.new(1)
	const a = world:server({ name = "A", players = 1 })
	const b = world:server({ name = "B", players = 1 })
	Sim.run(world.scheduler, "A", function()
		a.services.dataStores:GetOrderedDataStore("Board"):SetAsync("x", 7)
	end)
	Sim.run(world.scheduler, "B", function()
		const store = b.services.dataStores:GetOrderedDataStore("Board")
		Spec.equal(store:GetAsync("x"), 7)
		store:GetSortedAsync(false, 10)
	end)
	Spec.equal(a.budget.spent, { OrderedWrite = 1 })
	Spec.equal(b.budget.spent, { OrderedRead = 1, OrderedList = 1 })
end)

Spec.test("Ordered: a value that is not an integer is refused", function()
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const caught = Sim.catch(world.scheduler, "A", function()
		server.services.dataStores:GetOrderedDataStore("Board"):SetAsync("x", 1.5)
	end)
	Spec.truthy(caught ~= nil and string.find(caught, "104", 1, true) ~= nil, tostring(caught))
end)

Spec.test("Ordered: the write budget refills at 30 + 5 per player a minute", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 2, emptyBudget = true })
	local write, list = -1, -1
	Sim.run(world.scheduler, "A", function()
		world.scheduler:wait(60)
		write = server.services.dataStores:GetRequestBudgetForRequestType("OrderedWrite")
		list = server.services.dataStores:GetRequestBudgetForRequestType("OrderedList")
	end)
	Spec.equal(write, 40)
	Spec.equal(list, 9)
end)

Spec.test("Ordered: the in-memory store sorts and pages the same way", function()
	const store = MockOrdered.new({})
	fill(store)
	checkSorted(store)
end)

return nil
