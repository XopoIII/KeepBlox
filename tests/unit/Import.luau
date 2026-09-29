--!strict
--- Moving from another library (Import, Importers), with values in each library's documented format.
--- bench/ImportCheck.luau does the same with values the real libraries wrote in the simulator.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, level = 1 }

const function setup(options: { [string]: any }): (World.World, World.Server, KeepBlox.Store)
	const world = World.new(5)
	const server = world:server({ name = "A", players = 1 })
	const storeOptions: any = { template = TEMPLATE, services = server.services }
	for key, value in options do
		storeOptions[key] = value
	end
	return world, server, KeepBlox.store("Profiles", storeOptions)
end

const function stored(world: World.World, store: string, key: string): any
	const latest = world.backend:latest(`{store}/global`, key)
	return if latest then latest.value else nil
end

const function seed(world: World.World, server: World.Server, store: string, key: string, value: any)
	Sim.run(world.scheduler, "A", function()
		server.services.dataStores:GetDataStore(store):SetAsync(key, value)
	end, world.scheduler.now + 2)
end

const function docs(data: any, locked: boolean, at: number): any
	return {
		documentServiceSchemaVersion = 0,
		sessionLockId = "old",
		lockTimestamp = at,
		isLocked = locked,
		dataSchemaVersion = 1,
		lastCompatibleVersion = 1,
		data = data,
	}
end

Spec.test("Import: a new key takes the old library's data, and the old value is left as it was", function()
	const world, server, store = setup({ import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
	seed(world, server, "PlayerData", "u_1", docs({ coins = 70 }, false, 0))
	const before = #world.backend:versions("PlayerData/global", "u_1")
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data, { coins = 70, level = 1 })
		result.profile:release()
	end, 60)
	const record = stored(world, "Profiles", "u_1")
	Spec.equal(record.Data, { coins = 70, level = 1 })
	Spec.equal(record.MetaData.KeepBlox.importedFrom, "DocumentService")
	Spec.equal(#world.backend:versions("PlayerData/global", "u_1"), before, "the old store was not written")
end)

Spec.test("Import: a key the old library still holds is waited on, then taken with its last save", function()
	const world, server, store = setup({ import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
	const now = world.epoch
	seed(world, server, "PlayerData", "u_1", docs({ coins = 1 }, true, now))
	local result: any = nil
	world.scheduler:spawn(function()
		result = store:load("u_1")
	end, "A")
	world.scheduler:run(world.scheduler.now + 10)
	Spec.equal(result, nil, "still waiting on the old lock")
	seed(world, server, "PlayerData", "u_1", docs({ coins = 9 }, false, now + 10))
	world.scheduler:run(world.scheduler.now + 30)
	Spec.equal(result.ok, true)
	Spec.equal(result.profile.Data.coins, 9)
end)

Spec.test("Import: an old lock that never goes fails the load, and nothing is written", function()
	const world, server, store = setup({
		import = KeepBlox.importers.DocumentService({ store = "PlayerData" }),
		config = { loadTimeout = 20 },
	})
	seed(world, server, "PlayerData", "u_1", docs({ coins = 1 }, true, world.epoch + 10_000))
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:load("u_1")
	end, 60)
	Spec.equal(result, { ok = false, reason = "legacyLocked" })
	Spec.equal(stored(world, "Profiles", "u_1"), nil)
end)

Spec.test("Import: a failed read of the old store is retried, never taken for a new player", function()
	const world, server, store = setup({ import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
	seed(world, server, "PlayerData", "u_1", docs({ coins = 50 }, false, 0))
	world.faults:add({ op = "GetAsync", error = "502: API Services rejected request", times = 4 })
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:load("u_1")
	end, 120)
	Spec.equal(result.ok, true)
	Spec.equal(result.profile.Data.coins, 50)
end)

Spec.test("Import: a player the old library never saw starts from the template, at the current version", function()
	const world, _, store = setup({ import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_2")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data, TEMPLATE)
		result.profile:release()
	end, 60)
	Spec.equal(stored(world, "Profiles", "u_2").MetaData.KeepBlox.importedFrom, nil)
end)

Spec.test("Import: a key KeepBlox already has never reads the old store", function()
	const world, server, store = setup({ import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
	Sim.run(world.scheduler, "A", function()
		const first = store:load("u_1")
		assert(first.ok, "first")
		first.profile.Data.coins = 3
		first.profile:release()
	end, 60)
	seed(world, server, "PlayerData", "u_1", docs({ coins = 999 }, false, 0))
	Sim.run(world.scheduler, "A", function()
		const again = store:load("u_1")
		assert(again.ok, "again")
		Spec.equal(again.profile.Data.coins, 3)
	end, world.scheduler.now + 60)
end)

Spec.test("Import: an old value at the same key is converted in place, inside the claim (DataKeep)", function()
	const world, server, store = setup({ import = KeepBlox.importers.DataKeep({}) })
	const old = {
		Data = { coins = 12 },
		Metadata = { ActiveSession = nil, LastUpdate = 0, Created = 0, LoadCount = 4 },
		GlobalUpdates = { Id = 0, Updates = {} },
		UserIds = { 1 },
	}
	seed(world, server, "Profiles", "u_1", old)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data, { coins = 12, level = 1 })
		Spec.equal(result.profile.UserIds, { 1 })
		result.profile:release()
	end, 60)
	Spec.equal(stored(world, "Profiles", "u_1").MetaData.KeepBlox.importedFrom, "DataKeep")
	Spec.equal(world.backend:latest("Profiles__quarantine/global", "u_1"), nil, "not quarantined")
end)

Spec.test("Import: a same-key value the old library still holds is waited on (DataKeep)", function()
	const world, server, store = setup({ import = KeepBlox.importers.DataKeep({}), config = { loadTimeout = 20 } })
	seed(world, server, "Profiles", "u_1", {
		Data = { coins = 1 },
		Metadata = { ActiveSession = { PlaceId = 1, JobId = "old" }, LastUpdate = world.epoch + 10_000 },
		UserIds = {},
	})
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:load("u_1")
	end, 60)
	Spec.equal(result, { ok = false, reason = "legacyLocked" })
	Spec.equal(stored(world, "Profiles", "u_1").Data, { coins = 1 }, "left as it was")
end)

Spec.test("Import: DataStore2's newest ordered backup is the one taken", function()
	const world, server, store = setup({
		import = KeepBlox.importers.DataStore2({
			name = "DATA",
			userId = function(key: string): number?
				return tonumber(string.sub(key, 3))
			end,
		}),
	})
	Sim.run(world.scheduler, "A", function()
		const dataStores = server.services.dataStores
		dataStores:GetDataStore("DATA/7"):SetAsync("1", { coins = 1 })
		dataStores:GetDataStore("DATA/7"):SetAsync("2", { coins = 2 })
		dataStores:GetOrderedDataStore("DATA/7"):SetAsync("1", 1)
		dataStores:GetOrderedDataStore("DATA/7"):SetAsync("2", 2)
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data.coins, 2)
	end, 60)
end)

Spec.test("Import: Suphi's raw values, decoded when asked; a value that is not a table is refused", function()
	const world, server, store = setup({
		import = KeepBlox.importers.Suphi({
			store = "Player",
			decode = function(value: any): any
				return if type(value) == "string" then { coins = tonumber(value) } else value
			end,
		}),
	})
	seed(world, server, "Player", "u_1", { coins = 4 })
	seed(world, server, "Player", "u_2", "8")
	seed(world, server, "Player", "u_3", true)
	Sim.run(world.scheduler, "A", function()
		Spec.equal((store:load("u_1") :: any).profile.Data.coins, 4)
		Spec.equal((store:load("u_2") :: any).profile.Data.coins, 8)
		Spec.equal(store:load("u_3"), { ok = false, reason = "foreign" })
	end, 60)
end)

Spec.test("Import: Lapis's lock lasts 30 minutes from the key's last update", function()
	const world, server, store = setup({ import = KeepBlox.importers.Lapis({ store = "Lapis" }) })
	seed(
		world,
		server,
		"Lapis",
		"u_1",
		{ migrationVersion = 0, lastCompatibleVersion = 0, lockId = "x", data = { coins = 6 } }
	)
	local result: any = nil
	world.scheduler:spawn(function()
		result = store:load("u_1", {})
	end, "A")
	world.scheduler:run(world.scheduler.now + 100)
	Spec.equal(result, nil, "held by a live Lapis session")
	Spec.equal(stored(world, "Profiles", "u_1"), nil)
end)

Spec.test("Import: imported data runs every migration, from version 0", function()
	const world, server, store = setup({
		import = KeepBlox.importers.DocumentService({ store = "PlayerData" }),
		migrations = {
			[1] = function(data: any)
				data.coins *= 10
			end,
		},
	})
	seed(world, server, "PlayerData", "u_1", docs({ coins = 3 }, false, 0))
	Sim.run(world.scheduler, "A", function()
		Spec.equal((store:load("u_1") :: any).profile.Data.coins, 30)
	end, 60)
end)

return nil
