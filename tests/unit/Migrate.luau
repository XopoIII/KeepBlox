--!strict
--- Migrations: fixtures from before and after each step, and what a load does with them.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const S = KeepBlox.schema
const SCHEMA = S.record({
	coins = S.number({ default = 0, min = 0, integer = true }),
	stats = S.record({ wins = S.number(), losses = S.number() }),
})
const MIGRATIONS: { [number]: (data: any) -> ...any } = {
	-- 1: "gold" was renamed "coins".
	[1] = function(data: any)
		data.coins = data.gold
		data.gold = nil
	end,
	-- 2: wins and losses moved under "stats".
	[2] = function(data: any)
		data.stats = { wins = data.wins, losses = data.losses }
		data.wins, data.losses = nil, nil
	end,
}
const OPTIONS = { schema = SCHEMA, migrations = MIGRATIONS }

Spec.test("Migrate: each migration, from its fixture before to its fixture after", function()
	Spec.equal(KeepBlox.migrate(OPTIONS, { gold = 5, wins = 1, losses = 2 }, 0), {
		ok = true,
		data = { coins = 5, stats = { wins = 1, losses = 2 } },
		changed = true,
	})
	Spec.equal(KeepBlox.migrate(OPTIONS, { coins = 5, wins = 3, losses = 0 }, 1), {
		ok = true,
		data = { coins = 5, stats = { wins = 3, losses = 0 } },
		changed = true,
	})
	Spec.equal(KeepBlox.migrate(OPTIONS, { coins = 5, stats = { wins = 1, losses = 1 } }, 2), {
		ok = true,
		data = { coins = 5, stats = { wins = 1, losses = 1 } },
		changed = false,
	})
end)

Spec.test("Migrate: defaults fill what migrations leave out; the schema has the last word", function()
	Spec.equal(
		(KeepBlox.migrate(OPTIONS, { gold = 1 }, 0) :: any).data,
		{ coins = 1, stats = { wins = 0, losses = 0 } }
	)
	Spec.equal(KeepBlox.migrate(OPTIONS, { gold = -3 }, 0), {
		ok = false,
		reason = "schema",
		message = "the data does not fit the schema: Data.coins: -3 is below the minimum 0",
	})
	Spec.equal(KeepBlox.migrate(OPTIONS, { coins = 1 }, 5), {
		ok = false,
		reason = "newerSchema",
		message = "the data is at schema version 5, newer than this server's 2",
	})
end)

Spec.test("Migrate: numbering is checked when the store is made", function()
	Spec.throws(function()
		KeepBlox.migrate({ migrations = { [2] = function() end } }, {}, 0)
	end, "migration 1 is missing (they run 1..2)")
	Spec.throws(function()
		KeepBlox.migrate({ version = 1, migrations = MIGRATIONS }, {}, 0)
	end, "version 1 is below migration 2")
end)

const function setup(options: any?): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const store =
		KeepBlox.store("Profiles", options or { schema = SCHEMA, migrations = MIGRATIONS, services = server.services })
	const errors = {}
	store.onError:connect(function(_: string, message: string)
		table.insert(errors, message)
	end)
	return world, server, store, errors
end

const function put(server: World.Server, value: any)
	server.services.dataStores:GetDataStore("Profiles"):SetAsync("u_1", value)
end

const function stored(world: World.World): any
	return (world.backend:latest("Profiles/global", "u_1") :: any).value
end

Spec.test("Migrate: a ProfileStore record with no version is migrated on load and written with its version", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		put(server, {
			Data = { gold = 7, wins = 2, losses = 1 },
			MetaData = { SessionLoadCount = 0 },
			GlobalUpdates = { 0, {} },
		})
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data, { coins = 7, stats = { wins = 2, losses = 1 } })
		world.scheduler:wait(20)
		Spec.equal(stored(world).Data, { coins = 7, stats = { wins = 2, losses = 1 } })
		Spec.equal(stored(world).MetaData.KeepBlox.schemaVersion, 2)
		result.profile:release()
	end, 60)
end)

Spec.test("Migrate: data from a newer version is refused, the key let go, nothing written", function()
	const world, server, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		const newer = {
			Data = { coins = 1, stats = { wins = 0, losses = 0 }, future = true },
			MetaData = { SessionLoadCount = 0, KeepBlox = { lease = 0, schemaVersion = 3 } },
			GlobalUpdates = { 0, {} },
		}
		put(server, newer)
		Spec.equal(store:load("u_1"), { ok = false, reason = "newerSchema" })
	end, 60)
	Spec.equal(stored(world).Data, { coins = 1, stats = { wins = 0, losses = 0 }, future = true })
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
	Spec.equal(errors, { "the data is at schema version 3, newer than this server's 2" })
end)

Spec.test("Migrate: a failing migration refuses the load and leaves the data as it was", function()
	const world, server = setup()
	const store = KeepBlox.store("Profiles", {
		schema = SCHEMA,
		migrations = {
			[1] = function()
				error("bad step", 0)
			end,
			[2] = MIGRATIONS[2],
		},
		services = server.services,
	})
	Sim.run(world.scheduler, "A", function()
		put(server, { Data = { gold = 1 }, MetaData = { SessionLoadCount = 0 }, GlobalUpdates = { 0, {} } })
		Spec.equal(store:load("u_1"), { ok = false, reason = "migration" })
	end, 60)
	Spec.equal(stored(world).Data, { gold = 1 })
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
end)

Spec.test("Migrate: a save that breaks the schema is refused with its path", function()
	const world, _, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 4
		Spec.equal(result.profile:save(), true)
		result.profile.Data.coins = -1
		result.profile:save()
		result.profile.Data.coins = 5
		result.profile:release()
	end, 60)
	Spec.equal(errors, { "not saved: Data.coins: -1 is below the minimum 0" })
	Spec.equal(stored(world).Data.coins, 5)
end)

Spec.test("Migrate: a new player starts from the template as it is now, with no migration run on it", function()
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const store = KeepBlox.store("Profiles", {
		template = { coins = 5 },
		-- 1: coins were redenominated; the template already holds the new amount.
		migrations = {
			[1] = function(data: any)
				data.coins *= 10
			end,
		},
		services = server.services,
	})
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_new")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data, { coins = 5 })
		result.profile:release()
	end, 60)
	const record = (world.backend:latest("Profiles/global", "u_new") :: any).value
	Spec.equal(record.Data, { coins = 5 })
	Spec.equal(record.MetaData.KeepBlox.schemaVersion, 1)
end)

Spec.test("Migrate: a store takes a template or a schema, not both", function()
	Spec.throws(function()
		KeepBlox.store("P", { template = {}, schema = SCHEMA })
	end, "a template or a schema, and not both")
end)

return nil
