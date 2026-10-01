--!strict
--- The gate on a server's load retries while its data store fails (src/Gate.luau).
const Gate = require("@keepblox/Gate")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const FAILING = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"

type Run = {
	--> When each load answered, and whether it loaded.
	answered: { number },
	loaded: number,
	--> Load attempts the store refused.
	refused: number,
}

-- `loads` joins on one server over the first `spread` seconds, with the store down until `back`.
const function outage(seed: number, loads: number, spread: number, back: number, emptyBudget: boolean): Run
	const world = World.new(seed)
	const scheduler = world.scheduler
	const server = world:server({ name = "A", players = 1, emptyBudget = emptyBudget })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	const run: Run = { answered = {}, loaded = 0, refused = 0 }
	store.onError:connect(function(_: string, message: string)
		if string.find(message, "load attempt failed", 1, true) then
			run.refused += 1
		end
	end)
	Sim.run(scheduler, "A", function()
		world.faults:add({ op = "UpdateAsync", error = FAILING })
		for index = 1, loads do
			scheduler:spawn(function()
				scheduler:wait(scheduler.random:number() * spread)
				const result = store:load(`u_{index}`)
				table.insert(run.answered, scheduler.now)
				if result.ok then
					run.loaded += 1
				end
			end, "A")
		end
		scheduler:wait(back)
		world.faults:clear()
	end, back + 200)
	table.sort(run.answered)
	return run
end

Spec.test("Gate: while the store is down, a server's loads send one probe at a time", function()
	for seed = 1, 3 do
		const run = outage(seed, 20, 5, 60, false)
		Spec.equal(run.loaded, 20, `seed {seed}: every load landed`)
		-- Each load fails once or twice before the gate holds it, then one probe goes about each 1.2 s.
		-- Ungated, 20 loads backing off to 5 s are refused about 290 times in the minute.
		Spec.truthy(run.refused <= 100, `seed {seed}: {run.refused} attempts were refused`)
	end
end)

Spec.test("Gate: the probe that answers lets every waiting load go at once", function()
	for seed = 1, 3 do
		const run = outage(seed, 20, 5, 60, false)
		const last = run.answered[#run.answered]
		-- The next probe is at most a second and a call away; every load's own call follows it. Without
		-- the wake, a load sleeps out its own backoff of up to 5 s first.
		Spec.truthy(last <= 62, `seed {seed}: the last load answered at {last} s`)
	end
end)

Spec.test("Gate: an outage does not spend the budget its loads need once the store is back", function()
	for seed = 1, 3 do
		-- One player's budget and none saved up: 100 requests a minute, for 30 loads.
		const run = outage(seed, 30, 10, 60, true)
		const last = run.answered[#run.answered]
		Spec.equal(run.loaded, 30, `seed {seed}: every load landed`)
		-- Ungated, the retries spend the budget as it comes, and the last load lands near 78 s.
		Spec.truthy(last <= 68, `seed {seed}: the last load answered at {last} s`)
	end
end)

Spec.test("Gate: a lone failing load keeps its own backoff", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const server = world:server({ name = "A", players = 1 })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	local refused = 0
	store.onError:connect(function(_: string, message: string)
		if string.find(message, "load attempt failed", 1, true) then
			refused += 1
		end
	end)
	local ok = false
	Sim.run(scheduler, "A", function()
		world.faults:add({ op = "UpdateAsync", key = "u_1", error = FAILING })
		scheduler:spawn(function()
			ok = store:load("u_1").ok
		end, "A")
		scheduler:wait(30)
		world.faults:clear()
	end, 100)
	Spec.truthy(ok, "the load landed once the key answered")
	-- Tries at about 0, 1, 3, 7, 12, 17, 22 and 27 s: the waits 1, 2, 4, 5, 5, 5, 5, and each call's time.
	Spec.truthy(refused >= 7 and refused <= 8, `{refused} attempts were refused`)
end)

Spec.test("Gate: a key that fails does not hold the loads of keys that work", function()
	const world = World.new(2)
	const scheduler = world.scheduler
	const server = world:server({ name = "A", players = 10 })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	local longest, loaded = 0, 0
	Sim.run(scheduler, "A", function()
		for index = 1, 3 do
			world.faults:add({ op = "UpdateAsync", key = `bad_{index}`, error = FAILING })
			scheduler:spawn(function()
				store:load(`bad_{index}`)
			end, "A")
		end
		for index = 1, 40 do
			scheduler:spawn(function()
				scheduler:wait(scheduler.random:number() * 60)
				const began = scheduler.now
				if store:load(`u_{index}`).ok then
					loaded += 1
				end
				longest = math.max(longest, scheduler.now - began)
			end, "A")
		end
	end, 200)
	Spec.equal(loaded, 40)
	Spec.truthy(longest <= 0.5, `the longest load of a working key took {longest} s`)
end)

-- A retry leaves a reserve of the budget to saves (see Spare), so on a spent budget the probe waits
-- for requests before its call, and its load can end there.
Spec.test("Gate: a load that ends as the probe, before its call, frees the next one", function()
	const world = World.new(4)
	const scheduler = world.scheduler
	const server = world:server({ name = "A", players = 1 })
	-- The server's budget, as the library is told it: none once `spent`.
	local spent = false
	const real = server.services.dataStores
	const services = table.clone(server.services :: any)
	services.dataStores = setmetatable({
		GetRequestBudgetForRequestType = function(_: any, requestType: any): number
			return if spent then 0 else real:GetRequestBudgetForRequestType(requestType)
		end,
	}, { __index = real })
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	local cancelled = false
	local landedAt = -1
	Sim.run(scheduler, "A", function()
		world.faults:add({ op = "UpdateAsync", error = FAILING })
		for index = 1, 8 do
			scheduler:spawn(function()
				store:load(`u_{index}`, {
					cancel = function(): boolean
						return cancelled
					end,
				})
			end, "A")
		end
		scheduler:wait(5)
		Spec.truthy(Gate.open(services), "the store is failing")
		spent = true
		-- By now a load was let through as the probe, and waits for the budget.
		scheduler:wait(10)
		cancelled = true
		scheduler:wait(2)
		spent = false
		scheduler:spawn(function()
			if store:load("u_late").ok then
				landedAt = scheduler.now
			end
		end, "A")
		scheduler:wait(43)
		world.faults:clear()
	end, 300)
	-- The store is back at 60 s. With the probe never given up, no load probes again: this one waits
	-- out its whole `loadTimeout`.
	Spec.truthy(landedAt >= 60 and landedAt <= 70, `the late load landed at {landedAt} s`)
end)

Spec.test("Gate: a probe given up frees the next one", function()
	const world = World.new(3)
	const scheduler = world.scheduler
	const services = world:server({ name = "A", players = 1 }).services
	const function never(): boolean
		return false
	end
	local first, second = false, false
	Sim.run(scheduler, "A", function()
		Gate.note(services, false, false, 1)
		Gate.note(services, false, false, 1)
		Spec.truthy(Gate.open(services), "two calls in a row failed: the gate is open")
		first = Gate.wait(services, 0, 100, never)
		-- A second load cannot be the probe while the first is in flight.
		scheduler:spawn(function()
			second = Gate.wait(services, 0, 100, never)
		end, "A")
		scheduler:wait(5)
		Spec.equal(second, false, "one probe at a time")
		Gate.drop(services, first)
		scheduler:wait(1)
	end, 50)
	Spec.equal(first, true)
	Spec.equal(second, true, "the next load became the probe")
end)

return nil
