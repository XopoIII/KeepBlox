--!strict
--- What the gate on load retries (src/Gate.luau) saves and costs, in the simulator.
---
---     luneblox run bench/Retry [seeds]   (default 10)
---
--- Each scenario runs once per seed with the gate off (`every load`: each load retries at its own
--- backoff, as before the gate) and on (`gate`). The columns are means over the seeds, except the
--- longest load. `Requests` are data store requests of every kind; `Errors` are the `onError` reports.
const Gate = require("@keepblox/Gate")
const KeepBlox = require("@keepblox")
const World = require("@fakes/World")
const process = require("@lune/process")

type Shape = { name: string, gate: boolean }

const SHAPES: { Shape } = {
	{ name = "every load", gate = false },
	{ name = "gate", gate = true },
}

type Run = {
	started: number,
	loaded: number,
	failed: number,
	longest: number,
	seconds: { number },
	requests: number,
	errors: number,
	--> When the last load answered.
	settled: number,
}

type Bench = {
	world: World.World,
	stores: { any },
	servers: { World.Server },
	run: Run,
	owner: { [string]: number },
	load: (key: string, index: number) -> (),
}

const function bench(seed: number, shape: Shape, servers: number, players: number, empty: boolean): Bench
	Gate.enabled = shape.gate
	const world = World.new(seed)
	const scheduler = world.scheduler
	const run: Run =
		{ started = 0, loaded = 0, failed = 0, longest = 0, seconds = {}, requests = 0, errors = 0, settled = 0 }
	const stores = {}
	const list = {}
	for index = 1, servers do
		const server = world:server({ name = `S{index}`, players = players, emptyBudget = empty })
		const services = table.clone(server.services :: any)
		const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
		store.onError:connect(function()
			run.errors += 1
		end)
		stores[index] = store
		list[index] = server
	end
	const owner: { [string]: number } = {}
	const profiles: { [string]: any } = {}
	const self: Bench = {
		world = world,
		stores = stores,
		servers = list,
		run = run,
		owner = owner,
		load = function(key: string, index: number)
			run.started += 1
			const began = scheduler.now
			const result = stores[index]:load(key)
			const took = scheduler.now - began
			run.longest = math.max(run.longest, took)
			run.settled = scheduler.now
			if result.ok then
				owner[key] = index
				profiles[key] = result.profile
				run.loaded += 1
				table.insert(run.seconds, took)
			else
				run.failed += 1
			end
		end,
	}
	return self
end

const function finish(self: Bench, untilTime: number): Run
	self.world.scheduler:run(untilTime)
	for _, server in self.servers do
		for _, count in server.budget.spent do
			self.run.requests += count
		end
	end
	table.sort(self.run.seconds)
	return self.run
end

-- The live check's overload: three servers on one player's budget, 100 profiles each, one move every
-- quarter second for 300 s.
const function overload(seed: number, shape: Shape): Run
	const self = bench(seed, shape, 3, 1, true)
	const scheduler = self.world.scheduler
	scheduler:spawn(function()
		for index = 1, 3 do
			for slot = 1, 100 do
				scheduler:spawn(function()
					self.load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		for _ = 1, 1200 do
			scheduler:wait(0.25)
			const key = `k{scheduler.random:integer(1, 3)}_{scheduler.random:integer(1, 100)}`
			const target = scheduler.random:integer(1, 3)
			if self.owner[key] and self.owner[key] ~= target then
				scheduler:spawn(function()
					self.load(key, target)
				end, `S{target}`)
			end
		end
	end, "driver")
	return finish(self, 700)
end

-- The data store fails for a minute while 20 servers of 10 players take 200 joins, then recovers.
const function outage(seed: number, shape: Shape, players: number, seconds: number): Run
	const self = bench(seed, shape, 20, players, false)
	const scheduler = self.world.scheduler
	const failing = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
	scheduler:spawn(function()
		self.world.faults:add({ op = "UpdateAsync", error = failing })
		for index = 1, 20 do
			for slot = 1, players do
				scheduler:spawn(function()
					self.load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		scheduler:wait(seconds)
		self.world.faults:clear()
	end, "driver")
	return finish(self, 400)
end

-- The data store flickers for a minute, down and up every `period` seconds, under 200 joins.
const function flaky(seed: number, shape: Shape, period: number): Run
	const self = bench(seed, shape, 20, 10, false)
	const scheduler = self.world.scheduler
	const failing = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
	scheduler:spawn(function()
		for index = 1, 20 do
			for slot = 1, 10 do
				scheduler:spawn(function()
					scheduler:wait(scheduler.random:number() * 30)
					self.load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		for _ = 1, math.floor(30 / period) do
			self.world.faults:add({ op = "UpdateAsync", error = failing })
			scheduler:wait(period)
			self.world.faults:clear()
			scheduler:wait(period)
		end
	end, "driver")
	return finish(self, 400)
end

-- Three keys of each server never load (their writes fail), among 200 joins and moves that do.
const function poison(seed: number, shape: Shape): Run
	const self = bench(seed, shape, 20, 10, false)
	const scheduler = self.world.scheduler
	const failing = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
	scheduler:spawn(function()
		for index = 1, 20 do
			for slot = 1, 3 do
				self.world.faults:add({ op = "UpdateAsync", key = `bad{index}_{slot}`, error = failing })
				scheduler:spawn(function()
					self.load(`bad{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		for index = 1, 20 do
			for slot = 1, 10 do
				scheduler:spawn(function()
					scheduler:wait(scheduler.random:number() * 100)
					self.load(`k{index}_{slot}`, index)
					scheduler:wait(scheduler.random:number() * 20)
					self.load(`k{index}_{slot}`, index % 20 + 1)
				end, `S{index}`)
			end
		end
	end, "driver")
	return finish(self, 400)
end

-- The outage on a tight budget: ten servers with one player's budget and none saved up, 30 joins each
-- over the first ten seconds, the data store down for the first minute.
const function tight(seed: number, shape: Shape): Run
	const self = bench(seed, shape, 10, 1, true)
	const scheduler = self.world.scheduler
	const failing = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
	scheduler:spawn(function()
		self.world.faults:add({ op = "UpdateAsync", error = failing })
		for index = 1, 10 do
			for slot = 1, 30 do
				scheduler:spawn(function()
					scheduler:wait(scheduler.random:number() * 10)
					self.load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		scheduler:wait(60)
		self.world.faults:clear()
	end, "driver")
	return finish(self, 400)
end

-- Twenty servers on a spent budget: every player of the experience moves to the next server at once.
const function exodus(seed: number, shape: Shape): Run
	const self = bench(seed, shape, 20, 10, false)
	const scheduler = self.world.scheduler
	scheduler:spawn(function()
		for index = 1, 20 do
			for slot = 1, 10 do
				scheduler:spawn(function()
					self.load(`k{index}_{slot}`, index)
				end, `S{index}`)
			end
		end
		scheduler:wait(60)
		for round = 1, 3 do
			for index = 1, 20 do
				for slot = 1, 10 do
					const target = (index + round - 1) % 20 + 1
					scheduler:spawn(function()
						self.load(`k{index}_{slot}`, target)
					end, `S{target}`)
				end
			end
			scheduler:wait(60)
		end
	end, "driver")
	return finish(self, 500)
end

const function percentile(sorted: { number }, share: number): number
	if #sorted == 0 then
		return 0
	end
	return sorted[math.clamp(math.ceil(#sorted * share), 1, #sorted)]
end

const seeds = tonumber(process.args[1]) or 10
type Scenario = { name: string, fn: (seed: number, shape: Shape, a: number, b: number) -> Run, a: number?, b: number? }
const scenarios: { Scenario } = {
	{ name = "overload", fn = overload },
	{ name = "outage", fn = outage, a = 10, b = 60 },
	{ name = "herd", fn = outage, a = 40, b = 90 },
	{ name = "flaky 0.5s", fn = flaky, a = 0.5 },
	{ name = "flaky 3s", fn = flaky, a = 3 },
	{ name = "tight", fn = tight },
	{ name = "poison", fn = poison },
	{ name = "exodus", fn = exodus },
}
print("| Scenario | Retries | Loaded | Failed | p50 (s) | p99 (s) | Longest (s) | Settled (s) | Requests | Errors |")
print("|---|---|---|---|---|---|---|---|---|---|")
for _, scenario in scenarios do
	for _, shape in SHAPES do
		const sum = { loaded = 0, failed = 0, p50 = 0, p99 = 0, longest = 0, settled = 0, requests = 0, errors = 0 }
		for seed = 1, seeds do
			const run = scenario.fn(seed, shape, scenario.a or 0, scenario.b or 0)
			assert(run.loaded + run.failed == run.started, `{scenario.name} {shape.name} {seed}: a load never answered`)
			sum.loaded += run.loaded
			sum.failed += run.failed
			sum.p50 += percentile(run.seconds, 0.5)
			sum.p99 += percentile(run.seconds, 0.99)
			sum.longest = math.max(sum.longest, run.longest)
			sum.settled += run.settled
			sum.requests += run.requests
			sum.errors += run.errors
		end
		print(
			string.format(
				"| %s | %s | %.1f | %.1f | %.2f | %.2f | %.1f | %.1f | %.0f | %.1f |",
				scenario.name,
				shape.name,
				sum.loaded / seeds,
				sum.failed / seeds,
				sum.p50 / seeds,
				sum.p99 / seeds,
				sum.longest,
				sum.settled / seeds,
				sum.requests / seeds,
				sum.errors / seeds
			)
		)
	end
end
