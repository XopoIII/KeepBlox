--!strict
--- The fake DataStore: reads, writes, the cache, limits, versions and removal.
const Services = require("@keepblox/Services")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type DataStore = Services.DataStore

const function setup(seed: number?): (World.World, DataStore, DataStore)
	const world = World.new(seed or 1)
	const a = world:server({ name = "A" }).services.dataStores:GetDataStore("Profiles")
	const b = world:server({ name = "B" }).services.dataStores:GetDataStore("Profiles")
	return world, a, b
end

Spec.test("DataStore: a written value reads back, with its key info", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		const version = a:SetAsync("u_1", { coins = 5 }, { 1 }, { tag = "x" })
		const value, info = a:GetAsync("u_1", false)
		Spec.equal(value, { coins = 5 })
		assert(info, "key info")
		Spec.equal(info.Version, version)
		Spec.equal(info:GetUserIds(), { 1 })
		Spec.equal(info:GetMetadata(), { tag = "x" })
		Spec.equal(info.CreatedTime, info.UpdatedTime)
		Spec.equal(a:GetAsync("missing"), nil)
	end)
end)

Spec.test("DataStore: a read is a copy, never the stored table", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		const written = { list = { 1 } }
		a:SetAsync("k", written)
		written.list[1] = 99
		const first = a:GetAsync("k", false)
		first.list[1] = 42
		Spec.equal(a:GetAsync("k", false), { list = { 1 } })
	end)
end)

Spec.test("DataStore: a cached read is stale for 4 s, then fresh", function()
	const world, a, b = setup()
	const scheduler = world.scheduler
	Sim.run(scheduler, "A", function()
		a:SetAsync("k", 1)
	end)
	Sim.run(scheduler, "B", function()
		Spec.equal(b:GetAsync("k"), 1)
	end)
	Sim.run(scheduler, "A", function()
		a:SetAsync("k", 2)
	end)
	Sim.run(scheduler, "B", function()
		Spec.equal(b:GetAsync("k"), 1, "cached")
		Spec.equal(b:GetAsync("k", false), 2, "useCache = false reads through")
	end)
	Sim.run(scheduler, "A", function()
		a:SetAsync("k", 3)
	end)
	scheduler:run(scheduler.now + 4)
	Sim.run(scheduler, "B", function()
		Spec.equal(b:GetAsync("k"), 3, "after 4 s")
	end)
end)

Spec.test("DataStore: key names are 1-50 characters", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			a:GetAsync("")
		end, "101:")
		Spec.throws(function()
			a:SetAsync(string.rep("k", 51), 1)
		end, "102:")
		a:SetAsync(string.rep("k", 50), 1)
	end)
end)

Spec.test("DataStore: the value limit is 4,194,304 bytes of JSON, exactly", function()
	const world, a = setup()
	-- A string of n bytes encodes to n + 2 (its quotes).
	Sim.run(world.scheduler, "A", function()
		a:SetAsync("at", string.rep("x", 4_194_302))
		Spec.throws(function()
			a:SetAsync("over", string.rep("x", 4_194_303))
		end, "105:")
		Spec.equal(a:GetAsync("over", false), nil)
	end)
end)

Spec.test("DataStore: refused values write nothing", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		a:SetAsync("k", { ok = true })
		Spec.throws(function()
			a:SetAsync("k", { bad = "\xFF" })
		end, "104:")
		Spec.throws(function()
			a:SetAsync("k", nil)
		end, "Argument 2 missing or nil")
		Spec.equal(a:GetAsync("k", false), { ok = true })
	end)
	Spec.equal(#world.backend:versions("Profiles/global", "k"), 1)
end)

Spec.test("DataStore: writes within one UTC hour keep one backup version", function()
	const world, a = setup()
	const scheduler = world.scheduler
	Sim.run(scheduler, "A", function()
		a:SetAsync("k", 1)
		a:SetAsync("k", 2)
		-- The epoch (1,800,000,000 s) falls exactly on an hour boundary: these two stay in hour 0.
		scheduler:wait(2400)
		a:SetAsync("k", 3)
		scheduler:wait(1200)
		a:SetAsync("k", 3)
		a:SetAsync("k", 4)
		scheduler:wait(3600)
		a:SetAsync("k", 5)
		const pages = a:ListVersionsAsync("k")
		const versions = pages:GetCurrentPage()
		Spec.equal(#versions, 3)
		Spec.equal(pages.IsFinished, true)
		const values = {}
		for _, entry in versions do
			table.insert(values, (a:GetVersionAsync("k", entry.Version)))
		end
		Spec.equal(values, { 3, 4, 5 })
		const newest = a:ListVersionsAsync("k", false):GetCurrentPage()
		Spec.equal(newest[1].Version, versions[3].Version)
	end)
end)

-- The same steps, with the same answers, as the live check (Studio, 2026-09-30).
Spec.test("DataStore: versions as seen live: overwritten ids, tombstones, made-up and malformed ids", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		const ids = function(): { string }
			const found = {}
			for _, entry in a:ListVersionsAsync("k"):GetCurrentPage() do
				table.insert(found, entry.Version .. (if entry.IsDeleted then " deleted" else ""))
			end
			return found
		end
		a:SetAsync("k", 1)
		const first = ids()[1]
		a:SetAsync("k", 2)
		const second = ids()
		Spec.equal(#second, 1)
		Spec.equal(table.pack(a:GetVersionAsync("k", first)).n, 2)
		Spec.equal(a:GetVersionAsync("k", first), nil, "an id overwritten in its hour reads nil")
		a:RemoveAsync("k")
		const removed = ids()
		Spec.equal(#removed, 2, "the tombstone is a version of its own")
		Spec.equal(removed[1], second[1])
		Spec.truthy(string.find(removed[2], " deleted", 1, true) ~= nil, "the second is the tombstone")
		Spec.equal(a:GetVersionAsync("k", second[1]), 2)
		Spec.equal(a:GetVersionAsync("k", (string.gsub(removed[2], " deleted", ""))), nil)
		Spec.equal(a:GetAsync("k", false), nil)
		a:SetAsync("k", 3)
		const after = ids()
		Spec.equal(#after, 2, "the next write replaces the tombstone")
		Spec.equal(after[1], second[1])
		Spec.equal(a:GetVersionAsync("k", second[1]), 2)
		Spec.equal(a:GetVersionAsync("k", "08DF1E8F7889F793.0000999999.08DF1E8F7960BF6A.01"), nil)
		Spec.equal(a:GetVersionAsync("never", second[1]), nil)
		Spec.throws(function()
			a:GetVersionAsync("k", "not-a-version")
		end, "Error code: 25")
	end)
end)

Spec.test("DataStore: version pages advance, then refuse to go past the end", function()
	const world, a = setup()
	const scheduler = world.scheduler
	Sim.run(scheduler, "A", function()
		for index = 1, 5 do
			a:SetAsync("k", index)
			scheduler:wait(3600)
		end
		const pages = a:ListVersionsAsync("k", true, 0, 0, 2)
		const seen = {}
		while true do
			for _, entry in pages:GetCurrentPage() do
				table.insert(seen, (a:GetVersionAsync("k", entry.Version)))
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
		Spec.equal(seen, { 1, 2, 3, 4, 5 })
		Spec.throws(function()
			pages:AdvanceToNextPageAsync()
		end, "No pages to advance to.")
	end)
end)

Spec.test("DataStore: RemoveAsync returns what it removed and leaves a tombstone", function()
	const world, a = setup()
	Sim.run(world.scheduler, "A", function()
		a:SetAsync("k", { v = 1 }, { 7 })
		const removed, info = a:RemoveAsync("k")
		Spec.equal(removed, { v = 1 })
		assert(info, "key info")
		Spec.equal(info:GetUserIds(), { 7 })
		Spec.equal(a:GetAsync("k"), nil)
		Spec.equal(a:GetAsync("k", false), nil)
		Spec.equal(a:RemoveAsync("k"), nil)
		Spec.equal(a:RemoveAsync("never"), nil)
	end)
	const versions = world.backend:versions("Profiles/global", "k")
	Spec.equal(versions[#versions].deleted, true)
end)

Spec.test("DataStore: scopes and names are separate stores", function()
	const world = World.new(1)
	const services = world:server({ name = "A" }).services
	const plain = services.dataStores:GetDataStore("P")
	Spec.truthy(plain == services.dataStores:GetDataStore("P"), "one handle per name and scope")
	Sim.run(world.scheduler, "A", function()
		plain:SetAsync("k", 1)
		Spec.equal(services.dataStores:GetDataStore("P", "other"):GetAsync("k"), nil)
		Spec.equal(services.dataStores:GetDataStore("Q"):GetAsync("k"), nil)
	end)
end)

return nil
