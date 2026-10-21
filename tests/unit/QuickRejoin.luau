--!strict
--- A player who leaves while their load is in flight and joins the same server again (a quick rejoin, a
--- teleport that failed) is not told "open": the new load waits as the earlier one's heir and gets the
--- session it opens, wherever the earlier load stood. One claim in all, and no later than the earlier
--- load would have answered (src/Opening.luau, src/Settle.luau, src/Open.luau).
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Opening = require("@keepblox/Opening")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene
type Player = { left: boolean }
type Answer = { result: any, at: number }

-- Seconds a waiting load sleeps between two looks at its key (Settle's POLL): the heir's answer may
-- come that much after the moment the session was handed to it.
const POLL = 0.1

-- Starts a load of "u_1" on A for `player`, which runs at once up to its first yield. Returns its
-- thread and the answer, with the moment it came.
const function start(scene: Scene, player: Player): (thread, Answer)
	const scheduler = scene.world.scheduler
	const answer: Answer = { result = nil, at = -1 }
	local thread: thread? = nil
	scheduler:resume(function()
		thread = coroutine.running()
		const result = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		answer.at = scheduler.now
		answer.result = result
	end, "A")
	return thread :: thread, answer
end

-- Steps the world until every one of `answers` has come.
const function settle(scene: Scene, answers: { Answer }, label: string)
	local guard = 0
	while true do
		local waiting = false
		for _, answer in answers do
			waiting = waiting or answer.result == nil
		end
		if not waiting then
			return
		end
		assert(scene.world.scheduler:step() and guard < 100_000, `{label}: a load never answered`)
		guard += 1
	end
end

-- The load count of "u_1" as stored now, 0 for a key never stored here.
const function loads(world: World.World): number
	const record = LoadRig.stored(world)
	return if record then record.MetaData.SessionLoadCount else 0
end

-- The key is free of A and A opened nothing: then a load of it on A gets `coins`.
const function free(scene: Scene, coins: number, label: string)
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, `{label}: A let go of the key`)
	Spec.equal(next(scene.store:profiles()), nil, `{label}: no profile is open`)
	Sim.run(scene.world.scheduler, "A", function()
		const result = scene.store:load("u_1")
		assert(result.ok, `{label}: loaded again ({(result :: any).reason})`)
		Spec.equal(result.profile.Data.coins, coins, `{label}: the coins`)
		result.profile:release()
	end, scene.world.scheduler.now + 60)
end

for _, case in LoadScenes do
	Spec.test(`Quick rejoin: {case.name}, the player leaves at every point and joins again at once`, function()
		local points = 0
		while true do
			const scene = case.build()
			const world = scene.world
			const scheduler = world.scheduler
			-- The load nobody leaves makes exactly one claim: so must the two loads of a rejoin together.
			const claimed = loads(world) + 1
			const first: Player = { left = false }
			const _, earlier = start(scene, first)
			for _ = 1, points do
				scheduler:step()
			end
			if earlier.result ~= nil then
				break
			end
			assert(points < 2000, "the load never answered")
			const label = `left after {points} steps`
			first.left = true
			const _, rejoin = start(scene, { left = false })
			Spec.equal(rejoin.result, nil, `{label}: the rejoin waits, and is not told "open"`)
			settle(scene, { earlier, rejoin }, label)
			Spec.equal(earlier.result, { ok = false, reason = "cancelled" }, `{label}: the player who left`)
			assert(rejoin.result.ok, `{label}: the rejoin got {rejoin.result.reason}`)
			const profile = rejoin.result.profile
			Spec.equal(profile.Data.coins, case.coins, `{label}: the coins`)
			Spec.equal(profile:isActive(), true, `{label}: active`)
			Spec.equal(profile.loadCount, claimed, `{label}: one claim in all`)
			Spec.equal(LoadRig.heldBy(world, scene.server), true, `{label}: held by A`)
			Spec.equal(
				rejoin.at - earlier.at <= POLL,
				true,
				`{label}: the rejoin answered {rejoin.at - earlier.at} s after the earlier load`
			)
			Sim.run(scheduler, "A", function()
				profile.Data.coins = case.coins + 1
				profile:release()
			end, scheduler.now + 30)
			Spec.equal(LoadRig.stored(world).Data.coins, case.coins + 1, `{label}: the release stored the play`)
			Spec.equal(LoadRig.stored(world).MetaData.ActiveSession, nil, `{label}: the key is free`)
			Spec.equal(next(scene.store:profiles()), nil, `{label}: no profile is open`)
			Spec.equal(scene.errors, {}, `{label}: nothing was reported`)
			Spec.equal(#scheduler.failures, 0, `{label}: no thread failed`)
			points += 1
		end
		Spec.equal(points >= 3, true, `only {points} points`)
	end)
end

-- A load of a key another server holds and never hands over (it neither answers nor is dead yet), so
-- the load waits as long as the test wants.
const function waiting(): Scene
	return LoadRig.scene(4, function(world: World.World)
		LoadRig.owner(world)
		world.faults:add({ op = "UpdateAsync", server = "B", hang = true })
		world.faults:add({ op = "UpdateSortedMapAsync", server = "B", hang = true })
	end)
end

Spec.test('Quick rejoin: a second load while the first player is still there gets "open" at once', function()
	const scene = waiting()
	const scheduler = scene.world.scheduler
	const _, earlier = start(scene, { left = false })
	scheduler:run(scheduler.now + 3)
	Spec.equal(earlier.result, nil, "the first waits for the key")
	const started = scheduler.now
	const _, second = start(scene, { left = false })
	Spec.equal(second.result, { ok = false, reason = "open" })
	Spec.equal(second.at, started)
	scheduler:run(scheduler.now + 3)
	Spec.equal(earlier.result, nil, "the first still waits: nothing was handed away from it")
	Spec.equal(scene.errors, {})
end)

Spec.test("Quick rejoin: a rejoin that leaves again, or whose thread is cancelled, takes nothing", function()
	for _, way in { "left", "cancelled" } do
		const scene = waiting()
		const scheduler = scene.world.scheduler
		const first: Player = { left = false }
		const _, earlier = start(scene, first)
		scheduler:run(scheduler.now + 3)
		first.left = true
		const again: Player = { left = false }
		const thread, rejoin = start(scene, again)
		scheduler:run(scheduler.now + 3)
		Spec.equal({ earlier.result, rejoin.result }, {}, `{way}: the earlier load goes on for its heir`)
		if way == "left" then
			again.left = true
			settle(scene, { earlier, rejoin }, way)
			Spec.equal(rejoin.result, { ok = false, reason = "cancelled" }, `{way}: the rejoin`)
		else
			scheduler:cancel(thread)
			settle(scene, { earlier }, way)
			Spec.equal(rejoin.result, nil, `{way}: the cancelled caller never went on`)
		end
		Spec.equal(earlier.result, { ok = false, reason = "cancelled" }, `{way}: the earlier load gave up`)
		Spec.equal(scene.errors, {}, `{way}: nothing was reported`)
		Spec.equal(#scheduler.failures, 0, `{way}: no thread failed`)
		scene.world.faults:clear()
		free(scene, 6, way)
	end
end)

Spec.test("Quick rejoin: a player whose `cancel` turns back keeps the session, at every point", function()
	-- Back after 0, 1, 2, ... steps of the world, until the load answers before the player is back:
	-- the session is never handed to the heir from a caller who is there again.
	local points = 0
	local kept = 0
	while true do
		const scene = LoadRig.scene(3)
		const first: Player = { left = true }
		const _, earlier = start(scene, first)
		const _, rejoin = start(scene, { left = false })
		for _ = 1, points do
			scene.world.scheduler:step()
		end
		if earlier.result ~= nil then
			break
		end
		const label = `back after {points} steps`
		first.left = false
		settle(scene, { earlier, rejoin }, label)
		assert(earlier.result.ok, `{label}: the earlier load got {earlier.result.reason}`)
		Spec.equal(earlier.result.profile:isActive(), true, label)
		Spec.equal(rejoin.result, { ok = false, reason = "open" }, `{label}: nothing taken from a caller who is there`)
		Spec.equal(scene.errors, {}, label)
		Spec.equal(#scene.world.scheduler.failures, 0, label)
		if rejoin.at >= earlier.at then
			kept += 1
		end
		points += 1
	end
	Spec.equal(points >= 3, true, `only {points} points`)
	-- At some point the load ended before the heir looked again: there the load itself had to keep it.
	Spec.equal(kept > 0, true, "no point where the load ended first")
end)

Spec.test("Quick rejoin: who is gone, which heir still waits, and what the load looks at", function()
	const live = coroutine.create(function() end)
	const dead = coroutine.create(function() end)
	coroutine.resume(dead)
	const function answers(value: boolean): () -> boolean
		return function(): boolean
			return value
		end
	end
	-- Gone: the caller's thread was cancelled, or its `cancel` says the player left.
	Spec.equal(Opening.gone(Opening.new(live, nil)), false)
	Spec.equal(Opening.gone(Opening.new(live, answers(false))), false)
	Spec.equal(Opening.gone(Opening.new(live, answers(true))), true)
	Spec.equal(Opening.gone(Opening.new(dead, answers(false))), true)
	-- An heir waits while nothing was handed to it, its thread lives and its player is there.
	Spec.equal(Opening.wants(nil), false)
	Spec.equal(Opening.wants({ thread = live, cancel = nil, profile = nil }), true)
	Spec.equal(Opening.wants({ thread = live, cancel = answers(false), profile = nil }), true)
	Spec.equal(Opening.wants({ thread = live, cancel = answers(true), profile = nil }), false)
	Spec.equal(Opening.wants({ thread = dead, cancel = answers(false), profile = nil }), false)
	Spec.equal(Opening.wants({ thread = live, cancel = nil, profile = {} :: any }), false)
	-- The load looks at its caller's `cancel`, but goes on while an heir waits.
	Spec.equal(Opening.polled(Opening.new(live, nil)), nil)
	const left = Opening.new(live, answers(true))
	const look = Opening.polled(left) :: () -> boolean
	Spec.equal(look(), true, "no heir: the load gives up")
	left.heir = { thread = live, cancel = answers(false), profile = nil }
	Spec.equal(look(), false, "an heir waits: the load goes on")
	left.heir = { thread = live, cancel = answers(true), profile = nil }
	Spec.equal(look(), true, "the heir left too: the load gives up")
	Spec.equal((Opening.polled(Opening.new(live, answers(false))) :: () -> boolean)(), false)
end)

return nil
