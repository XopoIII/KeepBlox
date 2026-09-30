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
		Spec.equal(store:restore("u_1", oldest), { ok = true, purchasesSince = {} })
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data.coins, 1)
		result.profile:release()
	end, world.scheduler.now + 60)
end)

-- Seen live (2026-09-30): a support tool restored a version the release had just overwritten, and got
-- "notAProfile"; a mistyped id threw out of `restore`.
Spec.test("Versions: a version that is gone, or an id that is not one, is 'noVersion', never an error", function()
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 1
		result.profile:save()
		const listed = store:versions("u_1")[1].version
		result.profile.Data.coins = 2
		result.profile:release() -- the same hour: the version listed above is overwritten
		Spec.equal(store:restore("u_1", listed), { ok = false, reason = "noVersion" })
		Spec.equal(store:restore("u_1", "not-a-version"), { ok = false, reason = "noVersion" })
		Spec.equal(store:readVersion("u_1", listed), nil)
		Spec.equal(store:readVersion("u_1", "not-a-version"), nil)
		const now = store:load("u_1")
		assert(now.ok, "loaded again")
		Spec.equal(now.profile.Data.coins, 2)
		now.profile:release()
	end, 60)
end)

Spec.test("Versions: a restored version keeps its schema version, so later migrations run on it", function()
	const world = World.new(2)
	const server = world:server({ name = "A" })
	-- The game before and after migration 1 renamed "gold" to "coins".
	const before = KeepBlox.store("Profiles", { template = { gold = 0 }, services = server.services })
	const after = KeepBlox.store("Profiles", {
		template = { coins = 0 },
		services = server.services,
		migrations = {
			[1] = function(data: any)
				data.coins = data.gold
				data.gold = nil
			end,
		},
	})
	Sim.run(world.scheduler, "A", function()
		const old = before:load("u_1")
		assert(old.ok, "loaded before")
		old.profile.Data.gold = 7
		old.profile:release()
		world.scheduler:wait(3600)
		const new = after:load("u_1")
		assert(new.ok, "loaded after")
		Spec.equal(new.profile.Data, { coins = 7 })
		new.profile.Data.coins = 9
		new.profile:release()
		world.scheduler:wait(3600)
		Spec.equal(after:restore("u_1", after:versions("u_1")[1].version), { ok = true, purchasesSince = {} })
		const restored = after:load("u_1")
		assert(restored.ok, "loaded restored")
		Spec.equal(restored.profile.Data, { coins = 7 })
		restored.profile:release()
	end, 3 * 3600)
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
