--!strict
--- A schedule among servers and faults: each job runs once though several servers sweep at once, a
--- server that dies holding a job leaves it to another, a game's change made while a job runs wins,
--- a sweep leaves the budget's last writes to saves, and a put whose call failed lands once.
const Errors = require("@fakes/Errors")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function open(world: World.World, name: string, players: number?): (KeepBlox.Schedule, World.Server)
	const server = world:server({ name = name, players = players or 1 })
	return KeepBlox.schedule("Reminders", { services = server.services, claim = 60 }), server
end

Spec.test("Schedule: three servers sweeping at once run each job once", function()
	const world = World.new(11)
	const servers: { [string]: { jobs: KeepBlox.Schedule, server: World.Server } } = {}
	for _, name in { "A", "B", "C" } do
		const jobs, server = open(world, name)
		servers[name] = { jobs = jobs, server = server }
	end
	const runs: { [string]: number } = {}
	Sim.run(world.scheduler, "A", function()
		const jobs, server = servers.A.jobs, servers.A.server
		const now = server.services.clock.time()
		for index = 1, 12 do
			jobs:put(`u_{index}`, now + 5, index)
		end
	end, 120)
	world.scheduler:run(world.scheduler.now + 10)
	for name, pair in servers do
		world.scheduler:spawn(function()
			pair.jobs:sweep(function(key: string): KeepBlox.Handled
				-- a handler that takes its time, so the sweeps overlap
				pair.server.services.clock.wait(2)
				runs[key] = (runs[key] or 0) + 1
				return nil
			end)
		end, name)
	end
	world.scheduler:run(world.scheduler.now + 300)
	Spec.equal(#world.scheduler.failures, 0)
	for index = 1, 12 do
		Spec.equal(runs[`u_{index}`], 1)
	end
end)

Spec.test("Schedule: a job a dead server held is run by another once its claim expires", function()
	const world = World.new(12)
	const jobsA, a = open(world, "A")
	const jobsB, b = open(world, "B")
	local ranOnB = 0
	Sim.run(world.scheduler, "A", function()
		jobsA:put("u_1", a.services.clock.time(), true)
	end, 60)
	world.scheduler:spawn(function()
		jobsA:sweep(function(): KeepBlox.Handled
			a.services.clock.wait(1000)
			return nil
		end)
	end, "A")
	world.scheduler:run(world.scheduler.now + 5)
	a:crash()
	Sim.run(world.scheduler, "B", function()
		const early = jobsB:sweep(function(): KeepBlox.Handled
			ranOnB += 1
			return nil
		end)
		Spec.equal(early.busy, 1)
		b.services.clock.wait(61)
		jobsB:sweep(function(): KeepBlox.Handled
			ranOnB += 1
			return nil
		end)
	end, world.scheduler.now + 200)
	Spec.equal(ranOnB, 1)
end)

Spec.test("Schedule: a game's change made while a job runs wins over the handler's answer", function()
	const world = World.new(13)
	const jobsA, a = open(world, "A")
	const jobsB = open(world, "B")
	local swept: any = nil
	Sim.run(world.scheduler, "A", function()
		const now = a.services.clock.time()
		jobsA:put("u_1", now, "old")
		swept = jobsA:sweep(function(): KeepBlox.Handled
			-- meanwhile another server puts a new job on the key
			Spec.equal(jobsB:put("u_1", now + 30, "new").ok, true)
			return nil
		end)
		Spec.equal(jobsA:read("u_1"), { ok = true, job = { due = now + 30, data = "new" } })
	end, 120)
	Spec.equal(swept.done, 0)
	Spec.equal(swept.left, 1)
	Sim.run(world.scheduler, "A", function()
		a.services.clock.wait(31)
		local data: any = nil
		jobsA:sweep(function(_key: string, job: KeepBlox.Job): KeepBlox.Handled
			data = job.data
			return nil
		end)
		Spec.equal(data, "new")
	end, world.scheduler.now + 120)
end)

Spec.test("Schedule: a sweep reads nothing while the server's budget is nearly spent", function()
	const world = World.new(14)
	const jobs, server = open(world, "A")
	Sim.run(world.scheduler, "A", function()
		jobs:put("u_1", server.services.clock.time(), true)
		local runs = 0
		const handler = function(): KeepBlox.Handled
			runs += 1
			return nil
		end
		-- a reserve above the whole budget: the sweep takes nothing
		const held = jobs:sweep(handler, { reserve = 10000 })
		Spec.equal(runs, 0)
		Spec.equal(held, { done = 0, kept = 0, left = 0, failed = 0, dropped = 0, busy = 0, early = 0 })
		jobs:sweep(handler)
		Spec.equal(runs, 1)
	end, 120)
end)

Spec.test("Schedule: a put whose first try landed and then failed lands once, and is run once", function()
	const world = World.new(15)
	const jobs, server = open(world, "A")
	world.faults:add({
		op = "UpdateAsync",
		key = "u_1",
		server = "A",
		times = 1,
		error = Errors.rejected(),
		after = true,
	})
	local runs = 0
	Sim.run(world.scheduler, "A", function()
		const now = server.services.clock.time()
		Spec.equal(
			jobs:update("u_1", function(job: KeepBlox.Job?): KeepBlox.Job?
				return { due = now, data = (if job then job.data else 0) + 1 }
			end),
			{ ok = true, job = { due = now, data = 1 } }
		)
		jobs:sweep(function(_key: string, job: KeepBlox.Job): KeepBlox.Handled
			runs += job.data
			return nil
		end)
	end, 300)
	Spec.equal(runs, 1)
end)

Spec.test("Schedule: a job put while a sweep parks its key is found all the same", function()
	const world = World.new(16)
	const jobsA, a = open(world, "A")
	const jobsB, b = open(world, "B")
	Sim.run(world.scheduler, "A", function()
		jobsA:put("u_1", a.services.clock.time(), "gone")
		jobsA:remove("u_1")
	end, 60)
	-- the sweep's park of the dead key is held five seconds, and lands on what is there by then
	world.faults:add({ op = "OrderedUpdateAsync", key = "u_1", server = "A", times = 1, delay = 5 })
	world.scheduler:spawn(function()
		jobsA:sweep(function(): KeepBlox.Handled
			return nil
		end)
	end, "A")
	world.scheduler:run(world.scheduler.now + 1)
	local due = 0
	Sim.run(world.scheduler, "B", function()
		due = b.services.clock.time() + 10
		Spec.equal(jobsB:put("u_1", due, "new").ok, true)
	end, world.scheduler.now + 60)
	-- the park landed after the put, and the sweep read the record again and lowered the index to it
	Spec.equal(world.ordered["Reminders_due/global"]["u_1"], due)
	local data: any = nil
	Sim.run(world.scheduler, "B", function()
		b.services.clock.wait(15)
		jobsB:sweep(function(_key: string, job: KeepBlox.Job): KeepBlox.Handled
			data = job.data
			return nil
		end)
	end, world.scheduler.now + 120)
	Spec.equal(data, "new")
end)

return nil
