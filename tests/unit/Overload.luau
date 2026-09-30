--!strict
--- Overload, as the live check found it (GP_TEST, 2026-09-30): many profiles on servers with a single
--- player's budget, and players moving between servers all the time. There, loads kept polling a spent
--- budget, the owners' final saves were throttled, so hand-overs stalled and the polling grew; and a
--- load could run far past `loadTimeout`, each of its stages counting the timeout afresh.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const SERVERS = 3
const PER_SERVER = 100
const MOVES = 1200 -- one every quarter second: 300 s of moving

type Run = { started: number, answered: number, longest: number, moved: number, reasons: { [string]: number } }

const function overload(seed: number): Run
	const world = World.new(seed)
	const scheduler = world.scheduler
	const stores = {}
	for index = 1, SERVERS do
		const server = world:server({ name = `S{index}`, players = 1, emptyBudget = true })
		stores[index] = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	end
	const run: Run = { started = 0, answered = 0, longest = 0, moved = 0, reasons = {} }
	const owner: { [string]: number } = {}
	const function load(key: string, index: number)
		run.started += 1
		const began = scheduler.now
		const result = stores[index]:load(key)
		run.longest = math.max(run.longest, scheduler.now - began)
		run.answered += 1
		if result.ok then
			owner[key] = index
			run.moved += 1
		else
			const reason = (result :: any).reason
			run.reasons[reason] = (run.reasons[reason] or 0) + 1
		end
	end
	Sim.run(scheduler, "driver", function()
		for index = 1, SERVERS do
			for slot = 1, PER_SERVER do
				scheduler:spawn(function()
					load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		for _ = 1, MOVES do
			scheduler:wait(0.25)
			const key = `k{scheduler.random:integer(1, SERVERS)}_{scheduler.random:integer(1, PER_SERVER)}`
			const target = scheduler.random:integer(1, SERVERS)
			if owner[key] and owner[key] ~= target then
				scheduler:spawn(function()
					load(key, target)
				end, `S{target}`)
			end
		end
	end, MOVES / 4 + 400)
	return run
end

Spec.test("Overload: every load answers within loadTimeout and one call, however spent the budget", function()
	const bound = KeepBlox.defaults.loadTimeout + KeepBlox.defaults.callTimeout
	for seed = 1, 3 do
		const run = overload(seed)
		const where = `seed {seed}: {run.moved} loaded, {run.reasons.timeout or 0} timed out`
		Spec.equal(run.answered, run.started, `every load answered, {where}`)
		Spec.truthy(run.longest <= bound, `the longest load took {run.longest} s (bound {bound}), {where}`)
		-- Loads that leave the budget to saves keep hand-overs going: 683-692 loads land here, against
		-- 383-396 when every try fires at the spent budget.
		Spec.truthy(run.moved >= 600, `hand-overs kept going, {where}`)
	end
end)

-- A player back on server A while A still releases them: the load waits for that release, then for
-- server B, which took the key meanwhile and cannot hand it over. Both waits share one deadline.
Spec.test("Overload: a load's waits share one deadline: this server's release, then another owner", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const failing = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
	const a = KeepBlox.store(
		"Profiles",
		{ template = { coins = 0 }, services = world:server({ name = "A", players = 1 }).services }
	)
	const b = KeepBlox.store(
		"Profiles",
		{ template = { coins = 0 }, services = world:server({ name = "B", players = 1 }).services }
	)
	local took, reason = -1, ""
	Sim.run(scheduler, "A", function()
		const first = a:load("u_1")
		assert(first.ok, "A loaded")
		-- A's writes of u_1 fail for 100 s, so its release keeps trying.
		world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = failing })
		scheduler:spawn(function()
			first.profile:release()
		end, "A")
		scheduler:spawn(function()
			-- At 100 s B takes the key by force; A's release learns it lost, and ends. From then on B
			-- cannot write u_1, so it never hands it over.
			scheduler:wait(100)
			const result = b:load("u_1", { steal = true })
			assert(result.ok, "B took u_1")
			world.faults:clear()
			world.faults:add({ op = "UpdateAsync", key = "u_1", server = "B", error = failing })
		end, "B")
		scheduler:wait(1)
		const began = scheduler.now
		const again = a:load("u_1")
		took, reason = scheduler.now - began, if again.ok then "loaded" else (again :: any).reason
	end, 400)
	Spec.equal(reason, "timeout")
	Spec.truthy(took <= KeepBlox.defaults.loadTimeout + 2, `the load took {took} s`)
end)

return nil
