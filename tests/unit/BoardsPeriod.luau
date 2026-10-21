--!strict
--- Leaderboards with a period, the entry above a value, and reads while the list budget is spent.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

-- The wall clock starts 50 seconds into period 18,000,000 of 100 seconds, so the next period begins
-- at scheduler time 50.
const EPOCH = 1_800_000_050
const FIRST = 18_000_000

const function setup(periods: { number }?): (World.World, World.Server, KeepBlox.Store)
	const world = World.new(9, EPOCH)
	const server = world:server({ name = "A", players = 3 })
	const store = KeepBlox.store("Profiles", {
		template = { coins = 0 },
		services = server.services,
		leaderboards = {
			coins = function(data: any): number?
				return data.coins
			end,
			weekly = {
				read = function(data: any, period: number): number?
					if periods then
						table.insert(periods, period)
					end
					return data.coins
				end,
				period = { length = 100 },
			},
		},
	})
	return world, server, store
end

const function board(world: World.World, name: string): { [string]: number }
	return world.ordered[`Profiles__{name}/global`] or {}
end

const function fill(store: KeepBlox.Store, values: { number })
	for index, coins in values do
		const result = store:load(`u_{index}`)
		assert(result.ok, "loaded")
		result.profile.Data.coins = coins
		result.profile:release()
	end
end

Spec.test(
	"BoardsPeriod: a board with a period writes into the period's own store, and starts the next empty",
	function()
		const periods: { number } = {}
		const world, server, store = setup(periods)
		Sim.run(world.scheduler, "A", function()
			const result = store:load("u_1")
			assert(result.ok, "loaded")
			result.profile.Data.coins = 5
			result.profile:save()
			world.scheduler:wait(61)
			result.profile:save()
			world.scheduler:wait(1)
			result.profile:release()
			world.scheduler:wait(1)
		end, 200)
		Spec.equal(board(world, `weekly_{FIRST}`), { u_1 = 5 })
		Spec.equal(board(world, `weekly_{FIRST + 1}`), { u_1 = 5 }, "the same value, written again in the new period")
		Spec.equal(board(world, "weekly"), {}, "no store without the period")
		Spec.equal(board(world, "coins"), { u_1 = 5 })
		Spec.equal(server.budget.spent.OrderedWrite, 3, "the lasting board once, the weekly one once a period")
		Spec.equal(periods, { FIRST, FIRST + 1, FIRST + 1 })
	end
)

Spec.test("BoardsPeriod: the current period is read unless another is asked for", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:leaderboardPeriod("weekly"), FIRST)
		Spec.equal(store:leaderboardPeriod("coins"), nil, "a lasting board has no period")
		fill(store, { 30, 90 })
		world.scheduler:wait(60)
		Spec.equal(store:leaderboardPeriod("weekly"), FIRST + 1)
		fill(store, { 40 })
		world.scheduler:wait(1)
		Spec.equal(store:leaderboard("weekly"), { { key = "u_1", value = 40 } })
		Spec.equal(store:leaderboard("weekly", { period = FIRST }), {
			{ key = "u_2", value = 90 },
			{ key = "u_1", value = 30 },
		})
		Spec.equal(store:leaderboard("weekly", { period = FIRST - 1 }), {}, "a period nobody wrote is empty")
	end, 200)
end)

Spec.test("BoardsPeriod: a period is asked of a board with one, and is a whole number", function()
	const world, _, store = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			store:leaderboard("coins", { period = FIRST })
		end, `leaderboard "coins" has no period`)
		Spec.throws(function()
			store:leaderboard("weekly", { period = FIRST + 0.5 })
		end, "a period is a whole number")
		Spec.throws(function()
			store:leaderboardPeriod("gems")
		end, `no leaderboard named "gems"`)
	end, 5)
end)

Spec.test("BoardsPeriod: a period needs a positive length", function()
	const world = World.new(9, EPOCH)
	const server = world:server({ name = "A", players = 1 })
	for _, length in { 0, -1 } do
		Spec.throws(function()
			KeepBlox.store("Profiles", {
				template = {},
				services = server.services,
				leaderboards = {
					broken = {
						read = function(): number?
							return 1
						end,
						period = { length = length },
					},
				},
			})
		end, `leaderboard "broken" needs a period length`)
	end
end)

Spec.test("BoardsPeriod: the entry above a value is the lowest one higher than it", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		fill(store, { 30, 60, 90 })
		world.scheduler:wait(1)
		Spec.equal(store:leaderboardAbove("coins", 60), { key = "u_3", value = 90 })
		Spec.equal(store:leaderboardAbove("coins", 59), { key = "u_2", value = 60 })
		Spec.equal(store:leaderboardAbove("coins", 59.5), { key = "u_2", value = 60 }, "the lowest whole value above")
		Spec.equal(store:leaderboardAbove("coins", 90), nil, "nothing is above the top")
		Spec.equal(store:leaderboardAbove("weekly", 29), { key = "u_1", value = 30 })
		Spec.equal(store:leaderboardAbove("weekly", 29, { period = FIRST + 1 }), nil)
		const spent = server.budget.spent.OrderedList
		Spec.equal(store:leaderboardAbove("coins", 60), { key = "u_3", value = 90 })
		Spec.equal(server.budget.spent.OrderedList, spent, "kept for a minute")
	end, 100)
end)

Spec.test("BoardsPeriod: with the list budget spent, the last answer is given and no call is made", function()
	const world, server, store = setup()
	Sim.run(world.scheduler, "A", function()
		fill(store, { 30 })
		world.scheduler:wait(1)
		Spec.equal(store:leaderboard("coins"), { { key = "u_1", value = 30 } })
		fill(store, { 70 })
		world.scheduler:wait(61)
		const other = server.services.dataStores:GetOrderedDataStore("Other")
		while server.services.dataStores:GetRequestBudgetForRequestType("OrderedList") > 0 do
			other:GetSortedAsync(false, 1)
		end
		const spent = server.budget.spent.OrderedList
		Spec.equal(store:leaderboard("coins"), { { key = "u_1", value = 30 } }, "the old answer, not 70")
		Spec.equal(server.budget.spent.OrderedList, spent)
		Spec.throws(function()
			store:leaderboard("coins", { count = 5 })
		end, "the ordered list budget is spent")
		Spec.throws(function()
			store:leaderboardAbove("coins", 1)
		end, "the ordered list budget is spent")
	end, 200)
end)

return nil
