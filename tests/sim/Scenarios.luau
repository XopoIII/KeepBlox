--!strict
--- The named stories every library is run through (.claude/plan/05-test-harness.md). Each takes a seed
--- and an adapter and returns the simulation's report; `Scenarios.soak` runs one over many seeds and
--- keeps the worst of every metric, so a spec can state a bound that holds for all of them.
const Adapter = require("./Adapter")
const Ledger = require("./Ledger")
const Simulation = require("./Simulation")

export type Scenario = (seed: number, adapter: Adapter.Adapter) -> Simulation.Report

export type Soak = {
	violations: { Ledger.Violation },
	failures: { string },
	metrics: Ledger.Metrics,
	--> Slowest shutdown, and how many missed the 30 s deadline.
	maxShutdownSeconds: number,
	missedShutdowns: number,
}

const Scenarios = {}

--> A player leaves one server and joins another 0-5 s later.
function Scenarios.rejoin(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	const random = sim.scheduler.random
	a:join("u_1")
	sim:run(random:integer(10, 120))
	a:leave("u_1")
	sim:run(random:integer(0, 5))
	b:join("u_1")
	sim:run(60)
	b:leave("u_1")
	sim:run(60)
	return sim:finish()
end

--> A player arrives on another server while the old one still holds the session (a teleport before
--> the old server noticed the player left).
function Scenarios.handoff(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	a:join("u_1")
	sim:run(sim.scheduler.random:integer(10, 120))
	b:join("u_1")
	sim:run(10)
	a:leave("u_1")
	sim:run(120)
	b:leave("u_1")
	sim:run(60)
	return sim:finish()
end

--> The server crashes mid-play; the player comes back on another server.
function Scenarios.crash(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	a:join("u_1")
	sim:run(sim.scheduler.random:integer(30, 290))
	a:crash()
	b:join("u_1")
	sim:run(900)
	b:leave("u_1")
	sim:run(60)
	return sim:finish()
end

--> The owner is cut off from MessagingService and never hears that another server wants the key.
function Scenarios.partitioned(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	a:join("u_1")
	sim:run(sim.scheduler.random:integer(10, 120))
	sim.world.bus.partitioned.A = true
	b:join("u_1")
	sim:run(900)
	a:leave("u_1")
	b:leave("u_1")
	sim:run(120)
	return sim:finish()
end

--> Two more servers ask for a key the first holds, at the same moment.
function Scenarios.thirdRequester(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b, c = sim:server("A"), sim:server("B"), sim:server("C")
	a:join("u_1")
	sim:run(30)
	b:join("u_1")
	c:join("u_1")
	sim:run(300)
	for _, server in { a, b, c } do
		server:leave("u_1")
	end
	sim:run(120)
	return sim:finish()
end

--> Shutdown with 50 players while every data store call takes 1-3 s.
function Scenarios.shutdown(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a = sim:server("A", { name = "A", players = 50 })
	for index = 1, 50 do
		a:join(`u_{index}`)
	end
	sim:run(120)
	sim.world.faults.latency = { min = 1, max = 3 }
	a:shutdown()
	sim:run(120)
	return sim:finish()
end

--> Every data store call fails for two minutes; players keep playing, and one leaves meanwhile.
function Scenarios.outage(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	a:join("u_1")
	a:join("u_2")
	sim:run(60)
	sim.world.faults:add({ error = "502: API Services rejected request" })
	sim:run(30)
	a:leave("u_2")
	sim:run(90)
	sim.world.faults:clear()
	sim:run(60)
	b:join("u_2")
	sim:run(120)
	a:leave("u_1")
	b:leave("u_2")
	sim:run(120)
	return sim:finish()
end

--> Game code puts a string that is not valid UTF-8 into the data; the player plays on, leaves, and
--> comes back on another server.
function Scenarios.poison(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const a, b = sim:server("A"), sim:server("B")
	a:join("u_1")
	sim:run(sim.scheduler.random:integer(20, 60))
	a:edit("u_1", function(data: any)
		data.note = "\xFF"
	end)
	sim:run(200)
	a:leave("u_1")
	sim:run(5)
	b:join("u_1")
	sim:run(600)
	b:leave("u_1")
	sim:run(120)
	return sim:finish()
end

--> Random play on three servers over 10 keys for 20 minutes: joins, leaves, rejoins and crashes.
function Scenarios.soup(seed: number, adapter: Adapter.Adapter): Simulation.Report
	const sim = Simulation.new(seed, adapter)
	const random = sim.scheduler.random
	local servers = { sim:server("S1"), sim:server("S2"), sim:server("S3") }
	local next = 4
	const where: { [string]: any } = {}
	for _ = 1, 120 do
		const key = `u_{random:integer(1, 10)}`
		const roll = random:integer(1, 20)
		if roll == 1 then
			const victim = random:integer(1, #servers)
			servers[victim]:crash()
			for k, s in where do
				if s == servers[victim] then
					where[k] = nil
				end
			end
			servers[victim] = sim:server(`S{next}`)
			next += 1
		elseif where[key] then
			where[key]:leave(key)
			where[key] = nil
		else
			const target = servers[random:integer(1, #servers)]
			target:join(key)
			where[key] = target
		end
		sim:run(random:integer(1, 15))
	end
	for key, server in where do
		server:leave(key)
	end
	sim:run(900)
	return sim:finish()
end

--> Runs `scenario` for seeds 1..count and keeps every violation and the worst of every metric.
function Scenarios.soak(scenario: Scenario, adapter: Adapter.Adapter, count: number): Soak
	const result: Soak = {
		violations = {},
		failures = {},
		metrics = { maxProgressLost = 0, maxStaleSeconds = 0, maxOpenSeconds = 0, opens = 0, failedOpens = 0 },
		maxShutdownSeconds = 0,
		missedShutdowns = 0,
	}
	for seed = 1, count do
		const report = scenario(seed, adapter)
		for _, violation in report.violations do
			table.insert(result.violations, violation)
		end
		for _, failure in report.failures do
			table.insert(result.failures, `seed {seed}, {failure.group}: {failure.message}`)
		end
		const m, worst = report.metrics, result.metrics
		worst.maxProgressLost = math.max(worst.maxProgressLost, m.maxProgressLost)
		worst.maxStaleSeconds = math.max(worst.maxStaleSeconds, m.maxStaleSeconds)
		worst.maxOpenSeconds = math.max(worst.maxOpenSeconds, m.maxOpenSeconds)
		worst.opens += m.opens
		worst.failedOpens += m.failedOpens
		for _, shutdown in report.shutdowns do
			result.maxShutdownSeconds = math.max(result.maxShutdownSeconds, shutdown.seconds)
			if not shutdown.finished then
				result.missedShutdowns += 1
			end
		end
	end
	return result
end

--> Every story by name, for specs that run them all.
Scenarios.byName = {
	rejoin = Scenarios.rejoin,
	handoff = Scenarios.handoff,
	crash = Scenarios.crash,
	partitioned = Scenarios.partitioned,
	thirdRequester = Scenarios.thirdRequester,
	shutdown = Scenarios.shutdown,
	outage = Scenarios.outage,
	poison = Scenarios.poison,
	soup = Scenarios.soup,
} :: { [string]: Scenario }

return Scenarios
