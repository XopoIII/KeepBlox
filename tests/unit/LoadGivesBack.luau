--!strict
--- What a load that gives up as its claim lands gives back, request by request, and what a load
--- nobody stops still costs (src/LetGo.luau, src/Claim.luau, src/Open.luau, src/Enter.luau; issues 33
--- and 34). The sweeps are in tests/unit/LoadGivesUp.luau and LoadThrows.luau.
const GiveUpRig = require("./GiveUpRig")
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Sim = require("./Sim")
const Spec = require("../Spec")

type Scene = LoadRig.Scene

const NEW, HANDED, DEAD, IMPORTED, TRADE = LoadScenes[1], LoadScenes[2], LoadScenes[3], LoadScenes[4], LoadScenes[5]
Spec.equal({ NEW.name, DEAD.name, TRADE.name }, {
	"a key never stored",
	"a key whose owner died with newer play in its last beat",
	"a key with a trade its last server did not finish",
})

type Watch = {
	--> A's claim has landed: the store shows the key as A's.
	landed: boolean,
	--> The writes of "u_1" by A since then, as stored.
	writes: { any },
	--> A's memory store units and its data store requests when the claim landed.
	memory: number,
	requests: number,
	--> Runs once, as the claim lands.
	onLanded: (() -> ())?,
}

-- Watches A's writes of "u_1" from the one that makes the key A's.
const function watch(scene: Scene): Watch
	const watching: Watch = { landed = false, writes = {}, memory = 0, requests = 0, onLanded = nil }
	scene.world.backend:observe(function(event: any)
		if event.key ~= "u_1" or event.writer ~= "A" then
			return
		end
		if watching.landed then
			table.insert(watching.writes, event.version.value)
			return
		end
		const session = event.version.value.MetaData.ActiveSession
		if session ~= nil and session[2] == scene.server.services.jobId then
			watching.landed = true
			watching.memory = scene.world.memory.spent.A
			watching.requests = scene.server.budget.spent.StandardWrite
			if watching.onLanded then
				watching.onLanded()
			end
		end
	end)
	return watching
end

-- A's load of "u_1" whose player leaves as its claim lands; returns its answer, with A's memory store
-- units and data store requests since the claim landed.
const function leftAsItLanded(scene: Scene, watching: Watch, untilTime: number?): (any, number, number)
	const player = { left = false }
	watching.onLanded = function()
		player.left = true
	end
	local answer: any = nil
	local memory, requests = -1, -1
	Sim.run(scene.world.scheduler, "A", function()
		answer = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		memory = scene.world.memory.spent.A - watching.memory
		requests = scene.server.budget.spent.StandardWrite - watching.requests
	end, scene.world.scheduler.now + (untilTime or 60))
	return answer, memory, requests
end

Spec.test("Load gives back: a takeover given up as it lands stores the dead owner's last beat, then frees", function()
	const scene = DEAD.build()
	const watching = watch(scene)
	const answer, memory, requests = leftAsItLanded(scene, watching)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	-- One read of the dead owner's beat, one write of what it held, one write that frees the key.
	Spec.equal({ memory, requests, #watching.writes }, { 1, 2, 2 })
	const beat, freed = watching.writes[1], watching.writes[2]
	Spec.equal(beat.Data, { coins = 6 }, "the beat, stored")
	Spec.equal(beat.MetaData.ActiveSession[2], scene.server.services.jobId, "by the session that claimed")
	Spec.equal(beat.MetaData.KeepBlox.snap, 0)
	Spec.equal(freed.Data, { coins = 6 })
	Spec.equal(freed.MetaData.ActiveSession, nil, "then the key, freed")
	Spec.equal(freed.MetaData.SessionLoadCount, beat.MetaData.SessionLoadCount)
	Spec.equal(scene.errors, {})
	GiveUpRig.next(scene, "C", 6, GiveUpRig.FREE, "after the answer")
end)

Spec.test("Load gives back: a key with nothing behind it is freed with one write, as before", function()
	-- A key never stored has no previous owner; a key with an unfinished trade keeps its journal for
	-- the next load to settle, and nobody's beat is read for it.
	for _, case in { NEW, TRADE } do
		const scene = case.build()
		const watching = watch(scene)
		const answer, memory, requests = leftAsItLanded(scene, watching)
		Spec.equal(answer, { ok = false, reason = "cancelled" }, case.name)
		Spec.equal({ memory, requests, #watching.writes }, { 0, 1, 1 }, case.name)
		Spec.equal(watching.writes[1].MetaData.ActiveSession, nil, case.name)
		Spec.equal(watching.writes[1].MetaData.KeepBlox.trade ~= nil, case == TRADE, `{case.name}: the journal`)
		Spec.equal(scene.errors, {}, case.name)
		GiveUpRig.next(scene, "C", case.coins, GiveUpRig.FREE, case.name)
	end
end)

Spec.test("Load gives back: a give-back the store refuses is tried again, and each refusal reported", function()
	const scene = NEW.build()
	const scheduler = scene.world.scheduler
	const watching = watch(scene)
	const started = scheduler.now
	local landedAt = -1
	const player = { left = false }
	watching.onLanded = function()
		player.left = true
		landedAt = scheduler.now
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = "503: down", times = 2 })
	end
	local answer: any = nil
	local answeredAt = -1
	Sim.run(scheduler, "A", function()
		answer = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		answeredAt = scheduler.now
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "A holds the key after its answer")
	end, started + 60)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	Spec.equal(scene.errors, {
		"u_1: a key its load gave up was not given back: 503: down",
		"u_1: a key its load gave up was not given back: 503: down",
	})
	-- The load's backoff: a second, then two.
	const waited = answeredAt - landedAt
	Spec.equal(waited >= 3 and waited < 4, true, `the answer came {waited} s after the claim`)
	Spec.equal(#watching.writes, 1, "one write freed the key")
	GiveUpRig.next(scene, "C", 0, GiveUpRig.FREE, "after the answer")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Load gives back: a give-back the store never takes ends at the load's deadline, and says so", function()
	-- The dead owner's key, so that the claim lands seconds into the load: the tries end at the load's
	-- own deadline, not one counted from the give-back.
	const scene = LoadRig.scene(5, function(world)
		LoadRig.owner(world):crash()
	end, { config = { loadTimeout = 30 } })
	const scheduler = scene.world.scheduler
	const watching = watch(scene)
	const started = scheduler.now
	local landedAt = -1
	const player = { left = false }
	watching.onLanded = function()
		player.left = true
		landedAt = scheduler.now
	end
	-- The beat is stored; from then on the store takes no write of the key from A.
	scene.world.backend:observe(function(event: any)
		if #watching.writes == 1 and event.writer == "A" then
			scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = "503: down" })
		end
	end)
	local answer: any = nil
	local answeredAt = -1
	Sim.run(scheduler, "A", function()
		answer = scene.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		answeredAt = scheduler.now
	end, started + 200)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	Spec.equal(landedAt - started > 8, true, `the claim landed after {landedAt - started} s`)
	Spec.equal(answeredAt - started <= 30, true, `the answer came after {answeredAt - started} s`)
	-- Tried 0, 1, 3, 7, 12 and 17 seconds after the beat was stored: the backoff doubles up to five
	-- seconds, and a seventh try would come past the deadline.
	Spec.equal(#scene.errors, 6)
	for _, message in scene.errors do
		Spec.equal(message, "u_1: a key its load gave up was not given back: 503: down")
	end
	Spec.equal(#watching.writes, 1, "the beat")
	Spec.equal(watching.writes[1].Data, { coins = 6 })
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "the store took no other write: the key is still A's")
	-- The server lives on, and a later load of the key there claims it as its own, with the beat.
	scene.world.faults:clear()
	Sim.run(scheduler, "A", function()
		const again = scene.store:load("u_1")
		assert(again.ok, "loaded again")
		Spec.equal(again.profile.Data, { coins = 6 })
		again.profile:release()
	end, scheduler.now + 30)
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), false)
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Load gives back: a load that fails past its claim stores the last beat once, then frees", function()
	-- A migration that fails, on a key taken from a dead owner: the beat was stored before the data
	-- was looked at, and undoing the load does not read or store it again.
	const scene = LoadRig.scene(5, function(world)
		LoadRig.owner(world):crash()
	end, {
		version = 1,
		migrations = {
			function()
				error("no way up", 0)
			end,
		},
	})
	scene.options = nil
	const watching = watch(scene)
	local answer: any = nil
	local memory = -1
	Sim.run(scene.world.scheduler, "A", function()
		answer = scene.store:load("u_1")
		memory = scene.world.memory.spent.A - watching.memory
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "A holds the key after its answer")
	end, scene.world.scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "migration" })
	Spec.equal({ memory, #watching.writes }, { 1, 2 })
	Spec.equal(watching.writes[1].Data, { coins = 6 })
	Spec.equal(watching.writes[2].MetaData.ActiveSession, nil)
	Spec.equal(#scene.errors, 1)
	Spec.equal(string.find(scene.errors[1], "no way up", 1, true) ~= nil, true, scene.errors[1])
	GiveUpRig.next(scene, "C", 6, GiveUpRig.FREE, "after the answer")
end)

-- What a load nobody stops spends until it answers: data store reads and writes, memory store units,
-- messages published. The numbers are 0.6.8's, read from its sources with this same spec.
const COSTS: { [LoadScenes.Case]: { number } } = {
	[NEW] = { 1, 1, 1, 0 },
	[HANDED] = { 2, 2, 3, 1 },
	[DEAD] = { 13, 13, 16, 1 },
	[IMPORTED] = { 3, 1, 0, 0 },
	[TRADE] = { 13, 13, 15, 1 },
}

Spec.test("Load gives back: a load nobody stops answers as it did and spends what it did", function()
	for _, case in LoadScenes do
		const scene = case.build()
		const world = scene.world
		const spent = scene.server.budget.spent
		const before =
			{ spent.StandardRead or 0, spent.StandardWrite or 0, world.memory.spent.A, world.bus.published.A or 0 }
		local answer: any = nil
		local cost: { number } = {}
		Sim.run(world.scheduler, "A", function()
			answer = scene.store:load("u_1")
			cost = {
				(spent.StandardRead or 0) - before[1],
				(spent.StandardWrite or 0) - before[2],
				world.memory.spent.A - before[3],
				(world.bus.published.A or 0) - before[4],
			}
		end, world.scheduler.now + 60)
		assert(answer and answer.ok, `{case.name}: loaded`)
		Spec.equal(answer.profile.Data.coins, case.coins, case.name)
		Spec.equal(answer.profile:isActive(), true, case.name)
		Spec.equal(LoadRig.heldBy(world, scene.server), true, case.name)
		Spec.equal(cost, COSTS[case], case.name)
		Spec.equal(scene.errors, {}, case.name)
	end
end)

return nil
