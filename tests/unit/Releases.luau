--!strict
--- Game releases and the schema: every write stores data with the schema version it is at, whatever
--- path writes it (a save, a trade, a snapshot), so a migration never runs twice on the same data.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

-- 1: wins and losses moved under "stats", as a new table.
const WRAP = {
	[1] = function(data: any): any
		return { coins = data.coins, stats = { wins = data.wins } }
	end,
}

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

Spec.test("Releases: a trade right after a migrating load stores the schema version with its data", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 2 })
	const raw = server.services.dataStores:GetDataStore("Profiles")
	const store =
		KeepBlox.store("Profiles", { template = { coins = 0 }, migrations = WRAP, services = server.services })
	Sim.run(world.scheduler, "A", function()
		for _, key in { "u_a", "u_b" } do
			raw:SetAsync(
				key,
				{ Data = { coins = 10, wins = 3 }, MetaData = { SessionLoadCount = 0 }, GlobalUpdates = { 0, {} } }
			)
		end
		const a = store:load("u_a")
		const b = store:load("u_b")
		assert(a.ok and b.ok, "loaded")
		-- Before the first renewal writes the migrated data.
		Spec.equal(
			store:trade("u_a", "u_b", function(dataA: any, dataB: any)
				dataA.coins -= 4
				dataB.coins += 4
			end),
			{ ok = true }
		)
		a.profile:release()
		b.profile:release()
	end, 60)
	for key, coins in { u_a = 6, u_b = 14 } :: { [string]: number } do
		Spec.equal(stored(world, key).MetaData.KeepBlox.schemaVersion, 1, key)
		Spec.equal(stored(world, key).Data, { coins = coins, stats = { wins = 3 } }, key)
	end
	Sim.run(world.scheduler, "A", function()
		const again = store:load("u_a")
		assert(again.ok, "loaded again")
		Spec.equal(again.profile.Data, { coins = 6, stats = { wins = 3 } }, "migrated once")
		again.profile:release()
	end, world.scheduler.now + 60)
end)

-- Release 2 renames "coins" to "gold", and can be rolled back to release 1.
const RENAME = {
	up = function(data: any)
		data.gold, data.coins = data.coins, nil
	end,
	down = function(data: any)
		data.coins, data.gold = data.gold, nil
	end,
}
const RELEASE_1 = { template = { coins = 0, stats = { wins = 0 } }, migrations = WRAP }
const RELEASE_2 = {
	template = { gold = 0, stats = { wins = 0 } },
	migrations = { [1] = WRAP[1], [2] = RENAME },
	writeVersion = 1,
}
const RELEASE_3 = { template = { gold = 0, stats = { wins = 0 } }, migrations = { [1] = WRAP[1], [2] = RENAME } }

const function open(world: World.World, name: string, release: any): KeepBlox.Store
	const options = table.clone(release)
	options.services = world:server({ name = name }).services
	return KeepBlox.store("Profiles", options)
end

-- Loads `key` on `store`, applies `change` to its data, and returns the data it had.
const function play(store: KeepBlox.Store, key: string, change: ((data: any) -> ())?, keep: boolean?): any
	const result = store:load(key)
	assert(result.ok, `loaded ({(result :: any).reason})`)
	const seen = table.clone(result.profile.Data)
	if change then
		change(result.profile.Data)
	end
	if not keep then
		result.profile:release()
	end
	return seen
end

Spec.test("Releases: a release with writeVersion can be rolled back, and back again, losing nothing", function()
	const world = World.new(2)
	const two, one = open(world, "A", RELEASE_2), open(world, "B", RELEASE_1)
	Sim.run(world.scheduler, "A", function()
		Spec.equal(
			play(two, "u_1", function(data: any)
				data.gold = 5
			end),
			{ gold = 0, stats = { wins = 0 } },
			"a new player on release 2"
		)
		Spec.equal(stored(world, "u_1").Data, { coins = 5, stats = { wins = 0 } }, "stored as release 1 has it")
		Spec.equal(stored(world, "u_1").MetaData.KeepBlox.schemaVersion, 1)
		Spec.equal(
			play(one, "u_1", function(data: any)
				data.coins = 7
			end),
			{ coins = 5, stats = { wins = 0 } },
			"rolled back to release 1"
		)
		Spec.equal(
			play(two, "u_1", function(data: any)
				data.gold = 9
			end),
			{ gold = 7, stats = { wins = 0 } },
			"release 2 again"
		)
		Spec.equal(play(open(world, "C", RELEASE_3), "u_1"), { gold = 9, stats = { wins = 0 } }, "release 3")
		Spec.equal(stored(world, "u_1").MetaData.KeepBlox.schemaVersion, 2, "release 3 stores its own version")
		const refused = one:load("u_1")
		Spec.equal((refused :: any).reason, "newerSchema", "release 1 cannot read what release 3 wrote")
	end, 600)
end)

Spec.test("Releases: a crashed release-2 server's snapshot is taken over by release 1", function()
	const world = World.new(3)
	const two = open(world, "A", RELEASE_2)
	Sim.run(world.scheduler, "A", function()
		play(two, "u_1", function(data: any)
			data.gold = 3
		end, true)
		world.scheduler:wait(20)
	end, 30)
	world.scheduler:crash("A")
	world.bus:disconnectServer("A")
	Sim.run(world.scheduler, "B", function()
		Spec.equal(play(open(world, "B", RELEASE_1), "u_1"), { coins = 3, stats = { wins = 0 } })
	end, world.scheduler.now + 120)
end)

Spec.test("Releases: a trade on release 2 is read by release 1", function()
	const world = World.new(4)
	const server = world:server({ name = "A", players = 2 })
	const options = table.clone(RELEASE_2) :: any
	options.services = server.services
	const two = KeepBlox.store("Profiles", options)
	Sim.run(world.scheduler, "A", function()
		const a, b = two:load("u_a"), two:load("u_b")
		assert(a.ok and b.ok, "loaded")
		a.profile.Data.gold = 10
		Spec.equal(
			two:trade("u_a", "u_b", function(dataA: any, dataB: any)
				dataA.gold -= 4
				dataB.gold += 4
			end),
			{ ok = true }
		)
		a.profile:release()
		b.profile:release()
		const one = open(world, "B", RELEASE_1)
		Spec.equal(play(one, "u_a"), { coins = 6, stats = { wins = 0 } })
		Spec.equal(play(one, "u_b"), { coins = 4, stats = { wins = 0 } })
	end, 120)
end)

Spec.test("Releases: writeVersion is checked, and migrateDown runs the down steps on a fixture", function()
	Spec.throws(function()
		KeepBlox.store("Profiles", { template = {}, migrations = { [1] = WRAP[1] }, writeVersion = 0, mock = true })
	end, "migration 1 needs a down function (writeVersion is 0)")
	Spec.throws(function()
		KeepBlox.store("Profiles", { template = {}, migrations = WRAP, writeVersion = 2, mock = true })
	end, "writeVersion 2 must be a whole number from 0 to version 1")
	-- A down that does not undo its up (it drops the field) would change every player on a rollback.
	Spec.throws(function()
		KeepBlox.store("Profiles", {
			template = { gold = 1 },
			migrations = {
				[1] = {
					up = RENAME.up,
					down = function(data: any)
						data.gold = nil
					end,
				},
			},
			writeVersion = 0,
			mock = true,
		})
	end, "the template does not come back through migrations 1..1 down and up")
	const fixture = { gold = 4, stats = { wins = 1 } }
	Spec.equal(KeepBlox.migrateDown(RELEASE_3, fixture, 1), { ok = true, data = { coins = 4, stats = { wins = 1 } } })
	Spec.equal(
		(KeepBlox.migrate(RELEASE_3, { coins = 4, stats = { wins = 1 } }, 1) :: any).data,
		fixture,
		"up undoes down"
	)
	Spec.throws(function()
		KeepBlox.migrateDown(RELEASE_3, fixture, 0)
	end, "migration 1 has no down function")
end)

return nil
