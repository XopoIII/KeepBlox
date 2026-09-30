--!strict
--- What users of other data libraries lost data or players to, each as a spec against KeepBlox.
---
--- Every spec names the report it comes from: a GitHub issue (`<library>#<n>`) or a DevForum post of
--- the library's thread. The full list, with links, is in the docs site's guides/other-libraries page.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, items = {}, settings = { music = true } }

const function setup(players: number?): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(7)
	const server = world:server({ name = "A", players = players or 1 })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = server.services })
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

const function writes(world: World.World, key: string): number
	return #world.backend:versions("Profiles/global", key)
end

Spec.test(
	"Complaints: a quick rejoin into the same server waits for the release (DataKeep#21, DocumentService#126)",
	function()
		const world, server, store = setup()
		world.faults.latency = { min = 2, max = 2 }
		local second: any = nil
		Sim.run(world.scheduler, "A", function()
			const first = store:load("u_1")
			assert(first.ok, "first load")
			first.profile.Data.coins = 7
			-- PlayerRemoving releases (as task.spawn: at once, up to the first yield).
			server.services.clock.spawn(function()
				first.profile:release()
			end)
			-- The player is back before the release is stored.
			second = store:load("u_1")
		end, 120)
		Spec.equal(second.ok, true, "the rejoin loaded")
		Spec.equal(second.profile.Data.coins, 7, "with the released data")
		Spec.equal(second.profile.loadCount, 2)
		Spec.equal(second.profile:isActive(), true)
	end
)

Spec.test("Complaints: a second load of a live profile is still refused as open", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		assert((store:load("u_1") :: any).ok, "loaded")
		Spec.equal(store:load("u_1"), { ok = false, reason = "open" })
	end, 10)
end)

Spec.test(
	"Complaints: new template keys reach old profiles, deeply, and nothing is replaced (Suphi p11 #213)",
	function()
		const world, server, store = setup()
		Sim.run(world.scheduler, "A", function()
			const old =
				KeepBlox.store("Profiles", { template = { coins = 0, settings = {} }, services = server.services })
			const first = old:load("u_1")
			assert(first.ok, "old load")
			first.profile.Data.coins = 12
			first.profile.Data.settings.volume = 3
			first.profile:release()
			const result = store:load("u_1")
			assert(result.ok, "new load")
			Spec.equal(result.profile.Data, { coins = 12, items = {}, settings = { music = true, volume = 3 } })
		end, 120)
	end
)

Spec.test("Complaints: an autosave in flight never re-locks a released key (DocumentService#119)", function()
	const world, _, store = setup()
	world.faults.latency = { min = 3, max = 3 }
	const ended: { string } = {}
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		profile.Data.coins = 1
		world.scheduler:spawn(function()
			profile:save()
		end, "A")
		profile.onEnded:connect(function(reason: string)
			table.insert(ended, reason)
		end)
		profile.Data.coins = 2
		profile:release()
		Spec.equal(profile:save(), false, "a save after the release")
	end, 60)
	Spec.equal(ended, { "released" })
	const afterRelease = writes(world, "u_1")
	world.scheduler:run(world.scheduler.now + 120)
	const record = stored(world, "u_1")
	Spec.equal(record.MetaData.ActiveSession, nil, "released")
	Spec.equal(record.Data.coins, 2)
	Spec.equal(writes(world, "u_1"), afterRelease, "nothing wrote after the release")
end)

Spec.test("Complaints: a load after shutdown began is refused and writes nothing (DataStore2#126, Lapis#37)", function()
	const world, server, store = setup()
	local outcome: any = nil
	Sim.run(world.scheduler, "A", function()
		for _, callback in server.closing do
			callback()
		end
		outcome = store:load("u_1")
	end, 60)
	Spec.equal(outcome, { ok = false, reason = "closing" })
	Spec.equal(writes(world, "u_1"), 0)
end)

Spec.test("Complaints: a load in flight when shutdown begins gives the key back (Lapis#30)", function()
	const world, server, store = setup()
	world.faults.latency = { min = 2, max = 2 }
	local outcome: any = nil
	world.scheduler:spawn(function()
		outcome = store:load("u_1")
	end, "A")
	world.scheduler:run(world.scheduler.now + 3)
	Sim.run(world.scheduler, "A", function()
		for _, callback in server.closing do
			callback()
		end
	end, 60)
	Spec.equal(outcome, { ok = false, reason = "closing" })
	Spec.equal(stored(world, "u_1").MetaData.ActiveSession, nil, "the key is free")
end)

Spec.test("Complaints: a game BindToClose that spends the budget does not cost saves (ProfileStore p5 #104)", function()
	const world, server, store = setup(1)
	Sim.run(world.scheduler, "A", function()
		for index = 1, 10 do
			const result = store:load(`u_{index}`)
			assert(result.ok, "loaded")
			result.profile.Data.coins = index
		end
	end, 20)
	const other = server.services.dataStores:GetDataStore("GameStats")
	Sim.run(world.scheduler, "A", function()
		-- The game's own handler floods the write budget first: all of it, and a full queue beyond.
		for index = 1, server.budget:available("StandardWrite") + 120 do
			world.scheduler:spawn(function()
				pcall(other.SetAsync, other, `stat_{index}`, index)
			end, "A")
		end
		for _, callback in server.closing do
			world.scheduler:spawn(callback, "A")
		end
	end, world.scheduler.now + 30)
	for index = 1, 10 do
		const record = stored(world, `u_{index}`)
		Spec.equal(record.Data.coins, index, `u_{index} saved`)
		Spec.equal(record.MetaData.ActiveSession, nil, `u_{index} released`)
	end
end)

Spec.test("Complaints: a failed read never loads the template over saved data (ProfileStore p10 #195)", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		const first = store:load("u_1")
		assert(first.ok, "loaded")
		first.profile.Data.coins = 50
		first.profile:release()
	end, 60)
	world.faults:add({ op = "UpdateAsync", error = "502: API Services rejected request", times = 3 })
	world.faults:add({ op = "UpdateAsync", error = "503: the write was lost", after = true, times = 1 })
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:load("u_1")
	end, world.scheduler.now + 120)
	Spec.equal(result.ok, true)
	Spec.equal(result.profile.Data.coins, 50)
end)

Spec.test("Complaints: reading an old version never changes the live profile (DataKeep#22)", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		profile.Data.coins = 5
		profile:save()
		const versions = store:versions("u_1")
		const old = store:readVersion("u_1", versions[#versions].version)
		old.coins = 999
		Spec.equal(profile.Data.coins, 5)
		profile:save()
	end, 60)
	Spec.equal(stored(world, "u_1").Data.coins, 5)
end)

Spec.test("Complaints: a manual save does not end the session (ProfileStore p8 #153)", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		for index = 1, 10 do
			result.profile.Data.coins = index
			Spec.equal(result.profile:save(), true, `save {index}`)
		end
		Spec.equal(result.profile:isActive(), true)
		Spec.equal(result.profile.loadCount, 1)
	end, 120)
	Spec.equal(stored(world, "u_1").Data.coins, 10)
end)

Spec.test("Complaints: a save loop becomes a few writes, not an endless queue (Lapis#41)", function()
	const world, _, store, errors = setup()
	world.faults.latency = { min = 1, max = 1 }
	local results: { boolean } = {}
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const before = writes(world, "u_1")
		for index = 1, 200 do
			profile.Data.coins = index
			world.scheduler:spawn(function()
				table.insert(results, profile:save())
			end, "A")
		end
		world.scheduler:wait(10)
		Spec.truthy(writes(world, "u_1") - before <= 2, `wrote {writes(world, "u_1") - before} times`)
	end, 30)
	Spec.equal(#results, 200)
	for index, ok in results do
		Spec.equal(ok, true, `save {index}`)
	end
	Spec.equal(stored(world, "u_1").Data.coins, 200)
	Spec.equal(errors, {})
end)

return nil
