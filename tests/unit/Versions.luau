--!strict
--- Past versions: list, read, restore, and the ProfileStore names for them.
const CompatProfileStore = require("@keepblox/Compat/ProfileStore")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

-- A key saved with coins = 1, 2, 3 an hour apart, so each is its own backup version.
const function history(): (World.World, World.Server, KeepBlox.Store)
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	Sim.run(world.scheduler, "A", function()
		for coins = 1, 3 do
			const result = store:load("u_1")
			assert(result.ok, "loaded")
			result.profile.Data.coins = coins
			result.profile:release()
			world.scheduler:wait(3600)
		end
	end, 3 * 3600 + 60)
	return world, server, store
end

Spec.test("Versions: listed oldest first or newest first, and read back", function()
	const world, _, store = history()
	Sim.run(world.scheduler, "A", function()
		const versions = store:versions("u_1")
		Spec.equal(#versions, 3)
		Spec.truthy(versions[1].at < versions[3].at, "oldest first")
		const coins = {}
		for _, entry in versions do
			table.insert(coins, store:readVersion("u_1", entry.version).coins)
		end
		Spec.equal(coins, { 1, 2, 3 })
		Spec.equal(store:versions("u_1", { newestFirst = true, limit = 1 })[1].version, versions[3].version)
	end, world.scheduler.now + 60)
end)

Spec.test("Versions: restore brings back old data, and refuses while the key is held", function()
	const world, _, store = history()
	Sim.run(world.scheduler, "A", function()
		const oldest = store:versions("u_1")[1].version
		const held = store:load("u_1")
		assert(held.ok, "held")
		Spec.equal(store:restore("u_1", oldest), { ok = false, reason = "inUse" })
		held.profile:release()
		Spec.equal(store:restore("u_1", oldest), { ok = true })
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data.coins, 1)
		result.profile:release()
	end, world.scheduler.now + 60)
end)

Spec.test("Compat API: VersionQuery walks the versions as view profiles", function()
	const world, server = history()
	const ProfileStore = CompatProfileStore.withServices(server.services)
	Sim.run(world.scheduler, "A", function()
		const store = ProfileStore.New("Profiles", { coins = 0 })
		const query = store:VersionQuery("u_1")
		const seen = {}
		while true do
			const profile = query:NextAsync()
			if profile == nil then
				break
			end
			table.insert(seen, profile.Data.coins)
		end
		Spec.equal(seen, { 1, 2, 3 })
		const newest = store:VersionQuery("u_1", { Name = "Descending" }):NextAsync()
		Spec.equal(newest.Data.coins, 3)
	end, world.scheduler.now + 60)
end)

Spec.test("Compat API: MessageAsync and MessageHandler, exactly once", function()
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const ProfileStore = CompatProfileStore.withServices(server.services)
	Sim.run(world.scheduler, "A", function()
		const store = ProfileStore.New("Profiles", { gifts = 0 })
		Spec.equal(store:MessageAsync("u_1", { amount = 5 }), true)
		const profile = store:StartSessionAsync("u_1")
		profile:MessageHandler(function(message: any, processed: () -> ())
			profile.Data.gifts += message.amount
			processed()
		end)
		world.scheduler:wait(3)
		profile:EndSession()
		world.scheduler:wait(3)
		const view = store:GetAsync("u_1")
		Spec.equal(view.Data.gifts, 5)
		Spec.throws(function()
			view:MessageHandler(function() end)
		end, "not in view mode")
	end, 60)
	const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(record.GlobalUpdates[2], {})
end)

return nil
