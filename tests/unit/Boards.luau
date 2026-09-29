--!strict
--- Leaderboards beside the profiles (ProfileService#33, ProfileStore thread p5 #87/#101: declined there).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function setup(options: { [string]: any }?): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(9)
	const server = world:server({ name = "A", players = 3 })
	const storeOptions: any = {
		template = { coins = 0 },
		services = server.services,
		leaderboards = {
			coins = function(data: any): number?
				return data.coins
			end,
		},
	}
	for key, value in options or {} do
		storeOptions[key] = value
	end
	const store = KeepBlox.store("Profiles", storeOptions)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	return world, server, store, errors
end

const function board(world: World.World): { [string]: number }
	return world.ordered["Profiles__coins/global"] or {}
end

Spec.test("Boards: saved values reach the board, and the top comes back sorted", function()
	const world, _, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		for index, coins in { 30, 90, 60 } do
			const result = store:load(`u_{index}`)
			assert(result.ok, "loaded")
			result.profile.Data.coins = coins
			result.profile:release()
		end
		world.scheduler:wait(1)
		Spec.equal(store:leaderboard("coins", { count = 2 }), {
			{ key = "u_2", value = 90 },
			{ key = "u_3", value = 60 },
		})
		Spec.equal(store:leaderboard("coins", { count = 1, ascending = true }), { { key = "u_1", value = 30 } })
	end, 120)
	Spec.equal(board(world), { u_1 = 30, u_2 = 90, u_3 = 60 })
	Spec.equal(errors, {})
end)

Spec.test("Boards: a profile writes its board at most once a minute, always on release, and only changes", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		profile.Data.coins = 1
		profile:save()
		world.scheduler:wait(1)
		profile.Data.coins = 2
		profile:save()
		world.scheduler:wait(1)
		Spec.equal(board(world).u_1, 1, "the second save came too soon")
		profile:save()
		world.scheduler:wait(1)
		profile:release()
		world.scheduler:wait(1)
	end, 120)
	Spec.equal(board(world).u_1, 2, "the release wrote the last value")
	Spec.equal(server.budget.spent.OrderedWrite, 2)
end)

Spec.test("Boards: a value the board already holds is not written again", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 5
		result.profile:save()
		world.scheduler:wait(1)
		result.profile:release()
		world.scheduler:wait(1)
	end, 60)
	Spec.equal(board(world).u_1, 5)
	Spec.equal(server.budget.spent.OrderedWrite, 1)
end)

Spec.test("Boards: nil (or a value that is not a number) takes the key off the board; values are floored", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 7.9
		result.profile:save()
		world.scheduler:wait(1)
		Spec.equal(board(world).u_1, 7)
		result.profile.Data.coins = "none"
		result.profile:release()
		world.scheduler:wait(1)
	end, 120)
	Spec.equal(board(world).u_1, nil)
end)

Spec.test("Boards: a board function that throws is reported; the save itself is unharmed", function()
	const world, _, store, errors = setup({
		leaderboards = {
			broken = function(): number?
				error("no field", 0)
			end,
		},
	})
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.coins = 5
		Spec.equal(result.profile:save(), true)
		world.scheduler:wait(1)
	end, 60)
	Spec.equal(errors, { "u_1: leaderboard broken failed: no field" })
end)

Spec.test("Boards: an answer is kept for a minute, to spare the small list budget", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		store:leaderboard("coins")
		store:leaderboard("coins")
		world.scheduler:wait(61)
		store:leaderboard("coins")
	end, 120)
	Spec.equal(server.budget.spent.OrderedList, 2)
end)

Spec.test("Boards: with the ordered write budget spent, the board waits for a later save", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const ordered = server.services.dataStores:GetOrderedDataStore("Other")
		while server.services.dataStores:GetRequestBudgetForRequestType("OrderedWrite") > 0 do
			ordered:SetAsync("x", 1)
		end
		result.profile.Data.coins = 4
		result.profile:save()
		world.scheduler:wait(1)
		Spec.truthy(board(world).u_1 ~= 4, "skipped, not queued")
		world.scheduler:wait(60)
		result.profile:release()
		world.scheduler:wait(1)
	end, 200)
	Spec.equal(board(world).u_1, 4)
end)

Spec.test("Boards: asking a store without that board fails loudly", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			store:leaderboard("gems")
		end, `no leaderboard named "gems"`)
	end, 5)
end)

return nil
