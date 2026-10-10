--!strict
--- The loose ends of giving a key back (issue 37): a key a live server holds with no session is freed
--- for the server that asks for it, and a key a load may have taken unanswered is let go of with more
--- than one try (src/LetGo.luau, src/Upkeep.luau). A `cancel` that throws and a release that throws are
--- in tests/unit/LooseCancel.luau.
const GiveUpRig = require("./GiveUpRig")
const LoadRig = require("./LoadRig")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene

const DOWN = "503: down"
const FREED = "u_1: a key held with no session was freed for the server asking for it"

-- Runs `fn` once, as the write that makes "u_1" A's commits.
const function onLanded(scene: Scene, fn: () -> ())
	local landed = false
	scene.world.backend:observe(function(event: any)
		const session = event.version.value.MetaData.ActiveSession
		if not landed and event.writer == "A" and session ~= nil and session[2] == scene.server.services.jobId then
			landed = true
			fn()
		end
	end)
end

-- A's services, whose data store budget reads as spent while `spent.now`.
const function spending(spent: { now: boolean }): LoadRig.Dress
	return function(server: World.Server): any
		const services: any = table.clone(server.services)
		const dataStores: any = table.clone(services.dataStores)
		dataStores.GetRequestBudgetForRequestType = function(_: any, kind: any): number
			return if spent.now then 0 else server.services.dataStores:GetRequestBudgetForRequestType(kind)
		end
		services.dataStores = dataStores
		return services
	end
end

-- A's load of "u_1" gives up as its claim lands, and the store takes no write of the key from A until
-- the load's deadline (30 s): A lives on holding the key, with no session for it.
const function stray(): Scene
	const scene = LoadRig.scene(3, nil, { config = { loadTimeout = 30 } })
	const player = { left = false }
	onLanded(scene, function()
		player.left = true
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN })
	end)
	Sim.run(scene.world.scheduler, "A", function()
		const answer = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		Spec.equal(answer, { ok = false, reason = "cancelled" })
	end, scene.world.scheduler.now + 60)
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "the key is still A's")
	Spec.equal(next(scene.store:profiles()), nil, "A has no session for it")
	scene.world.faults:clear()
	table.clear(scene.errors)
	scene.options = nil
	return scene
end

Spec.test("Loose ends: a key a live server holds with no session is freed for the server that asks", function()
	const scene = stray()
	const scheduler = scene.world.scheduler
	const writes = scene.server.budget.spent.StandardWrite
	-- A beats, so no newcomer ever judges it dead: before 0.6.10 this load ran out its 120 s. Now A
	-- frees the key at the beat that brings the request (every 4 s), and C has it half a second later.
	const took = GiveUpRig.next(scene, "C", 0, 6, "a stray key")
	Spec.equal(took > 0.5, true, `C waited for A's beat ({took} s)`)
	Spec.equal(scene.errors, { FREED })
	Spec.equal(scene.server.budget.spent.StandardWrite - writes, 1, "one request of A's freed it")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Loose ends: a stray key is left alone while the store loads it, and when the count has moved", function()
	-- A loads the key again as C asks for it: the request finds a load, then a session, and the
	-- session is handed over as any other.
	const scene = stray()
	const scheduler = scene.world.scheduler
	local profile: any = nil
	Sim.run(scheduler, "A", function()
		const again = scene.store:load("u_1")
		assert(again.ok, "A loaded the key it held")
		profile = again.profile
		profile.Data.coins = 3
	end, scheduler.now + 10)
	const ended: { string } = {}
	profile.onEnded:connect(function(reason: string)
		table.insert(ended, reason)
	end)
	const reads = scene.server.budget.spent.StandardRead
	GiveUpRig.next(scene, "C", 3, 6, "a key loaded again")
	Spec.equal(ended, { "handedOver" })
	Spec.equal(scene.errors, {}, "nothing was stray")
	-- The request C left in A's beat names a session A has released itself: it costs A nothing more
	-- than the release, one request.
	Sim.run(scheduler, "A", function()
		scheduler:wait(30)
	end, scheduler.now + 40)
	Spec.equal(scene.server.budget.spent.StandardRead - reads, 1, "A's requests for the key it handed over")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Loose ends: a key a load may have taken unanswered is let go of at the second try", function()
	const scene = LoadRig.scene(3)
	const scheduler = scene.world.scheduler
	const player = { left = false }
	-- The claim lands and its answer is lost; the first try to let go is refused.
	scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN, after = true, times = 1 })
	onLanded(scene, function()
		player.left = true
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN, times = 1 })
	end)
	local answeredAt = -1
	Sim.run(scheduler, "A", function()
		const answer = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		answeredAt = scheduler.now
		Spec.equal(answer, { ok = false, reason = "cancelled" })
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "the load answered while the key was held")
		-- `backoffMin` (1 s) after the try that failed.
		scheduler:wait(2)
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "let go of in the background")
	end, scheduler.now + 60)
	Spec.equal(answeredAt >= 0, true)
	Spec.equal(scene.errors, { `u_1: load attempt failed: {DOWN}` }, "a try that is made again is not reported")
	GiveUpRig.next(scene, "C", 0, GiveUpRig.FREE, "after the answer")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Loose ends: a key that could never be let go of is reported once, after `loadTimeout`", function()
	const scene = LoadRig.scene(3, nil, { config = { loadTimeout = 30 } })
	const scheduler = scene.world.scheduler
	const player = { left = false }
	scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN, after = true, times = 1 })
	onLanded(scene, function()
		player.left = true
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN })
	end)
	local answeredAt, reportedAt = -1, -1
	scene.store.onError:connect(function()
		reportedAt = scheduler.now
	end)
	Sim.run(scheduler, "A", function()
		scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		answeredAt = scheduler.now
	end, scheduler.now + 120)
	const reportedAfter = reportedAt - answeredAt
	Spec.equal(scene.errors, {
		`u_1: load attempt failed: {DOWN}`,
		`u_1: a key its load may have taken could not be let go: {DOWN}`,
	})
	-- Tried 0, 1, 3, 7, 12, 17, 22 and 27 seconds after the answer; a ninth try would come past 30.
	Spec.equal(reportedAfter >= 27 and reportedAfter < 30, true, `it gave up {reportedAfter} s after the answer`)
	-- The key is still A's: the backstop frees it for whoever asks.
	scene.world.faults:clear()
	table.clear(scene.errors)
	scene.options = nil
	GiveUpRig.next(scene, "C", 0, 6, "after the tries")
	Spec.equal(scene.errors, { FREED })
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Loose ends: a load's tries to let go have a window of their own, and leave saves their budget", function()
	-- The store refuses every write of A's from the claim that landed unanswered on, so the load runs
	-- out its deadline (20 s): the tries to let go begin only then.
	const spent = { now = false }
	const scene = LoadRig.scene(3, nil, { config = { loadTimeout = 20 } }, spending(spent))
	const scheduler = scene.world.scheduler
	scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN, after = true, times = 1 })
	onLanded(scene, function()
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN })
	end)
	Sim.run(scheduler, "A", function()
		Spec.equal(scene.store:load("u_1"), { ok = false, reason = "timeout" })
		-- Five seconds past the load's deadline the store answers again: the next try lands.
		scheduler:wait(5)
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "held while the store refused")
		scene.world.faults:clear()
		-- But the budget is spent: no try is fired at it.
		spent.now = true
		const writes = scene.server.budget.spent.StandardWrite
		scheduler:wait(10)
		Spec.equal(scene.server.budget.spent.StandardWrite, writes, "no request while the budget was spent")
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), true)
		spent.now = false
		scheduler:wait(1)
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "let go of once the budget was back")
	end, scheduler.now + 120)
	for _, message in scene.errors do
		Spec.equal(message, `u_1: load attempt failed: {DOWN}`)
	end
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Loose ends: a key is not freed under a load of it, and a refused freeing is reported", function()
	-- A takes the key from dead B and parks before the write of B's last beat, its budget spent for
	-- 12 s. C asks meanwhile: A's beat brings the request while the load is in flight, and the key
	-- stays A's.
	const spent = { now = false }
	const scene = LoadRig.scene(5, function(world: World.World)
		LoadRig.owner(world):crash()
	end, nil, spending(spent))
	const scheduler = scene.world.scheduler
	onLanded(scene, function()
		spent.now = true
		const other = LoadRig.store(scene.world, "C")
		scheduler:spawn(function()
			other:load("u_1")
		end, "C")
		scheduler:spawn(function()
			scheduler:wait(12)
			spent.now = false
		end, "A")
	end)
	local loaded: any = nil
	Sim.run(scheduler, "A", function()
		const started = scheduler.now
		loaded = scene.store:load("u_1")
		Spec.equal(scheduler.now - started > 12, true, "the load was parked while C asked")
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "A holds the key its load answered with")
	end, scheduler.now + 60)
	assert(loaded and loaded.ok, "A loaded")
	Spec.equal(loaded.profile.Data.coins, 6)
	Spec.equal(scene.errors, {}, "nothing was stray")
	-- A stray key whose freeing the store refuses: said, and freed for the next server that asks.
	const stuck = stray()
	stuck.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = DOWN, times = 1 })
	const first = LoadRig.store(stuck.world, "C", { config = { loadTimeout = 10 } })
	Sim.run(stuck.world.scheduler, "C", function()
		Spec.equal(first:load("u_1"), { ok = false, reason = "timeout" })
	end, stuck.world.scheduler.now + 30)
	Spec.equal(stuck.errors, { `u_1: a key held with no session was not freed for the server asking for it: {DOWN}` })
	GiveUpRig.next(stuck, "D", 0, 6, "asked again")
	Spec.equal(stuck.errors[2], FREED)
end)

return nil
