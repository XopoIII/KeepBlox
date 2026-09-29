--!strict
--- What a library costs a server, measured in the simulator over the same fakes for every library:
---
--- - `hour`: 20 players join within a minute, play an hour, and leave. Data store requests (by budget
---   type) and MessagingService publishes are counted and given per player per hour. The budget is what
---   runs out first on a busy server, so this is the cost that matters.
--- - `storm`: 50 players join one server at the same moment. How long their loads take (p50, p99, max),
---   and how many fail.
---
--- CPU time is not compared across libraries: in Roblox the engine serializes a value natively, and in
--- the simulator it does not, so a library's own CPU cost cannot be separated fairly here. KeepBlox's
--- own frame cost is measured by bench/Run.luau.
const Adapter = require("@sim/Adapter")
const Simulation = require("@sim/Simulation")

export type HourCost = {
	--> Requests per player per hour, by budget type.
	perPlayerHour: { [string]: number },
	--> MessagingService publishes per player per hour.
	publishes: number,
	violations: number,
	failures: number,
}

export type StormCost = { p50: number, p99: number, max: number, failed: number, total: number }

const PLAYERS = 20
const STORM = 50

const Cost = {}

--> The hour of play for `adapter`.
function Cost.hour(adapter: Adapter.Adapter, seed: number): HourCost
	const sim = Simulation.new(seed, adapter)
	const a = sim:server("A", { name = "A", players = PLAYERS })
	const random = sim.scheduler.random
	for index = 1, PLAYERS do
		sim:run(random:number() * 60 / PLAYERS)
		a:join(`u_{index}`)
	end
	sim:run(3600)
	for index = 1, PLAYERS do
		a:leave(`u_{index}`)
	end
	sim:run(120)
	const report = sim:finish()
	const perPlayerHour: { [string]: number } = {}
	for requestType, count in a.server.budget.spent do
		perPlayerHour[requestType] = count / PLAYERS
	end
	return {
		perPlayerHour = perPlayerHour,
		publishes = (sim.world.bus.published.A or 0) / PLAYERS,
		violations = #report.violations,
		failures = #report.failures,
	}
end

const function percentile(sorted: { number }, share: number): number
	if #sorted == 0 then
		return 0
	end
	return sorted[math.clamp(math.ceil(#sorted * share), 1, #sorted)]
end

--> 50 players joining at once, for `adapter`.
function Cost.storm(adapter: Adapter.Adapter, seed: number): StormCost
	const sim = Simulation.new(seed, adapter)
	const a = sim:server("A", { name = "A", players = STORM })
	sim:run(1)
	for index = 1, STORM do
		a:join(`u_{index}`)
	end
	sim:run(300)
	const report = sim:finish()
	const times = table.clone(report.metrics.openSeconds)
	table.sort(times)
	return {
		p50 = percentile(times, 0.5),
		p99 = percentile(times, 0.99),
		max = percentile(times, 1),
		failed = report.metrics.failedOpens,
		total = report.metrics.opens + report.metrics.failedOpens,
	}
end

return Cost
