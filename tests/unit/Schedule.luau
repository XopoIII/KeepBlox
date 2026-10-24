--!strict
--- A schedule: jobs due at a time, kept in a data store and run once by whichever server sweeps first
--- (src/Schedule.luau, src/Sweep.luau, src/JobIndex.luau).
const JobIndex = require("@keepblox/JobIndex")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function open(
	world: World.World,
	name: string,
	options: KeepBlox.ScheduleOptions?
): (KeepBlox.Schedule, World.Server)
	const server = world:server({ name = name, players = 1 })
	const given: KeepBlox.ScheduleOptions = if options then table.clone(options) else {}
	given.services = server.services
	return KeepBlox.schedule("Reminders", given), server
end

--> The index's second for `key`, nil for none.
const function indexed(world: World.World, key: string): number?
	const values = world.ordered["Reminders_due/global"]
	return if values then values[key] else nil
end

Spec.test("Schedule: a job is run once its time has come, and then is gone", function()
	const world = World.new(1)
	const jobs, server = open(world, "A")
	const ran: { string } = {}
	local swept: any = nil
	Sim.run(world.scheduler, "A", function()
		const now = server.services.clock.time()
		Spec.equal(
			jobs:put("u_1", now + 60, { kind = "crop" }),
			{ ok = true, job = { due = now + 60, data = { kind = "crop" } } }
		)
		Spec.equal(indexed(world, "u_1"), now + 60)
		swept = jobs:sweep(function(key: string, job: KeepBlox.Job): KeepBlox.Handled
			table.insert(ran, `{key}:{job.data.kind}`)
			return nil
		end)
		Spec.equal(swept.done, 0)
		server.services.clock.wait(61)
		swept = jobs:sweep(function(key: string, job: KeepBlox.Job): KeepBlox.Handled
			table.insert(ran, `{key}:{job.data.kind}`)
			return nil
		end)
		Spec.equal(jobs:read("u_1"), { ok = true, job = nil })
	end, 300)
	Spec.equal(ran, { "u_1:crop" })
	Spec.equal(swept, { done = 1, kept = 0, left = 0, failed = 0, dropped = 0, busy = 0, early = 0 })
	Spec.equal(indexed(world, "u_1"), JobIndex.PARKED)
end)

Spec.test("Schedule: a handler keeps a job for later, or leaves it, or throws, and it comes again", function()
	const world = World.new(2)
	const jobs, server = open(world, "A")
	const errors: { string } = {}
	jobs.onError:connect(function(_key: string, _message: string, kind: string)
		table.insert(errors, kind)
	end)
	const answers: { string } = { "keep", "leave", "throw", "done" }
	const heard: { number } = {}
	Sim.run(world.scheduler, "A", function()
		const clock = server.services.clock
		jobs:put("u_1", clock.time(), { step = 1 })
		for _ = 1, 4 do
			jobs:sweep(function(_key: string, job: KeepBlox.Job): KeepBlox.Handled
				table.insert(heard, job.data.step)
				const answer = table.remove(answers, 1)
				if answer == "keep" then
					return { due = clock.time() + 30, data = { step = job.data.step + 1 } }
				elseif answer == "leave" then
					return false
				elseif answer == "throw" then
					error("the mail is down", 0)
				end
				return nil
			end)
			clock.wait(31)
		end
		Spec.equal(jobs:read("u_1"), { ok = true, job = nil })
	end, 600)
	Spec.equal(heard, { 1, 2, 2, 2 })
	Spec.equal(errors, { "schedule" })
end)

Spec.test("Schedule: a job moved later is found early once, and run at its new time", function()
	const world = World.new(3)
	const jobs, server = open(world, "A")
	local ranAt: number? = nil
	local early: any = nil
	Sim.run(world.scheduler, "A", function()
		const clock = server.services.clock
		const now = clock.time()
		jobs:put("u_1", now + 10, "first")
		jobs:put("u_1", now + 100, "later")
		-- the index never moves later on a game's change: it still says the first time
		Spec.equal(indexed(world, "u_1"), now + 10)
		clock.wait(20)
		early = jobs:sweep(function(): KeepBlox.Handled
			ranAt = clock.time()
			return nil
		end)
		Spec.equal(indexed(world, "u_1"), now + 100)
		clock.wait(90)
		jobs:sweep(function(_key: string, job: KeepBlox.Job): KeepBlox.Handled
			ranAt = clock.time()
			Spec.equal(job, { due = now + 100, data = "later" })
			return nil
		end)
	end, 300)
	Spec.equal(early.early, 1)
	Spec.equal(early.done, 0)
	Spec.equal(ranAt ~= nil, true)
end)

Spec.test("Schedule: a removed job is never run, and its index entry is parked", function()
	const world = World.new(4)
	const jobs, server = open(world, "A")
	local runs = 0
	Sim.run(world.scheduler, "A", function()
		const clock = server.services.clock
		jobs:put("u_1", clock.time() + 5, true)
		Spec.equal(jobs:remove("u_1"), { ok = true, job = nil })
		clock.wait(10)
		const swept = jobs:sweep(function(): KeepBlox.Handled
			runs += 1
			return nil
		end)
		Spec.equal(swept.early, 1)
	end, 120)
	Spec.equal(runs, 0)
	Spec.equal(indexed(world, "u_1"), JobIndex.PARKED)
end)

Spec.test("Schedule: a job no sweep finished is dropped past `keep`", function()
	const world = World.new(5)
	const jobs, server = open(world, "A", { keep = 600 })
	local runs = 0
	local swept: any = nil
	Sim.run(world.scheduler, "A", function()
		const clock = server.services.clock
		jobs:put("u_1", clock.time(), true)
		clock.wait(601)
		swept = jobs:sweep(function(): KeepBlox.Handled
			runs += 1
			return nil
		end)
	end, 900)
	Spec.equal(runs, 0)
	Spec.equal(swept.dropped, 1)
	Spec.equal(indexed(world, "u_1"), JobIndex.PARKED)
end)

Spec.test("Schedule: what cannot be a job is refused, and a key that is not one is not touched", function()
	const world = World.new(6)
	const jobs, server = open(world, "A")
	Sim.run(world.scheduler, "A", function()
		const now = server.services.clock.time()
		Spec.equal(
			jobs:put("u_1", 0 / 0, true),
			{ ok = false, reason = "refused", message = "a job's due is a time in seconds" }
		)
		Spec.equal(
			jobs:put("u_1", -5, true),
			{ ok = false, reason = "refused", message = "a job's due is a time in seconds" }
		)
		Spec.equal(
			jobs:put("u_1", now, { bad = 0 / 0 }),
			{ ok = false, reason = "refused", message = "data.bad: NaN cannot be stored" }
		)
		Spec.equal(
			jobs:update("u_1", function()
				error("nope", 0)
			end),
			{ ok = false, reason = "error", message = "nope" }
		)
		server.services.dataStores:GetDataStore("Reminders"):SetAsync("u_2", { coins = 5 })
		Spec.equal(jobs:put("u_2", now, true), { ok = false, reason = "foreign" })
		Spec.equal(jobs:read("u_2"), { ok = false, reason = "foreign" })
	end, 120)
	Spec.equal(world.backend:latest("Reminders/global", "u_1"), nil)
	Spec.equal(indexed(world, "u_1"), nil)
	Spec.equal((world.backend:latest("Reminders/global", "u_2") :: any).value, { coins = 5 })
end)

Spec.test("Schedule: an update changes the job it finds, in one write", function()
	const world = World.new(7)
	const jobs, server = open(world, "A")
	Sim.run(world.scheduler, "A", function()
		const now = server.services.clock.time()
		jobs:put("u_1", now + 50, { egg = now + 50 })
		const result = jobs:update("u_1", function(job: KeepBlox.Job?): KeepBlox.Job?
			const data = (job :: KeepBlox.Job).data
			data.scouts = now + 20
			return { due = math.min(data.egg, data.scouts), data = data }
		end)
		Spec.equal(result, { ok = true, job = { due = now + 20, data = { egg = now + 50, scouts = now + 20 } } })
		Spec.equal(indexed(world, "u_1"), now + 20)
	end, 120)
end)

return nil
