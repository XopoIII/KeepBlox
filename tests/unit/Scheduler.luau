--!strict
const Scheduler = require("@fakes/Scheduler")
const Sim = require("./Sim")
const Spec = require("../Spec")

-- Three threads that each log their name at every yield; returns the log.
const function interleaving(seed: number): { string }
	const scheduler = Scheduler.new(seed)
	const log = {}
	for _, name in { "a", "b", "c" } do
		scheduler:spawn(function()
			for _ = 1, 4 do
				table.insert(log, name)
				scheduler:wait(0)
			end
		end, name)
	end
	scheduler:run()
	return log
end

Spec.test("Scheduler: the same seed replays the same interleaving", function()
	Spec.equal(interleaving(123), interleaving(123))
end)

Spec.test("Scheduler: different seeds give different interleavings", function()
	const first = table.concat(interleaving(1))
	local differs = false
	for seed = 2, 20 do
		if table.concat(interleaving(seed)) ~= first then
			differs = true
			break
		end
	end
	Spec.truthy(differs, "some seed in 2..20 orders differently from seed 1")
end)

Spec.test("Scheduler: the earliest wake always runs first, and time jumps to it", function()
	const scheduler = Scheduler.new(5)
	const log: { string } = {}
	scheduler:spawn(function()
		scheduler:wait(3)
		table.insert(log, `late@{scheduler.now}`)
	end, "s")
	scheduler:spawn(function()
		scheduler:wait(1.5)
		table.insert(log, `early@{scheduler.now}`)
	end, "s")
	Spec.equal(scheduler:run(), 4)
	Spec.equal(log, { "early@1.5", "late@3" })
	Spec.equal(scheduler.now, 3)
end)

Spec.test("Scheduler: wait returns the virtual time slept, and spawn passes arguments", function()
	const scheduler = Scheduler.new(1)
	local slept, got = -1, {}
	scheduler:spawn(function(a: number, b: string, c: nil, d: boolean)
		got = { a, b, c, d }
		slept = scheduler:wait(2.25)
	end, "s", 1, "two", nil, true)
	scheduler:run()
	Spec.equal(slept, 2.25)
	Spec.equal(got, { 1, "two", nil, true })
end)

Spec.test("Scheduler: run(untilTime) stops exactly there and leaves later threads waiting", function()
	const scheduler = Scheduler.new(1)
	local woke = false
	scheduler:spawn(function()
		scheduler:wait(10)
		woke = true
	end, "s")
	scheduler:run(4)
	Spec.equal(scheduler.now, 4)
	Spec.equal(woke, false)
	Spec.equal(scheduler:count(), 1)
	scheduler:run()
	Spec.equal(woke, true)
	Spec.equal(scheduler:count(), 0)
end)

Spec.test("Scheduler: a spawned thread inherits its parent's group", function()
	const scheduler = Scheduler.new(1)
	local childGroup: string? = nil
	Sim.run(scheduler, "parent", function()
		scheduler:spawn(function()
			childGroup = scheduler:currentGroup()
		end)
	end)
	Spec.equal(childGroup, "parent")
	Spec.equal(scheduler:currentGroup(), nil)
end)

Spec.test("Scheduler: crash drops one group's threads at their yield point", function()
	const scheduler = Scheduler.new(1)
	const log: { string } = {}
	for _, group in { "a", "b" } do
		scheduler:spawn(function()
			table.insert(log, `{group} before`)
			scheduler:wait(5)
			table.insert(log, `{group} after`)
		end, group)
	end
	scheduler:run(1)
	Spec.equal(scheduler:crash("a"), 1)
	scheduler:run()
	table.sort(log)
	Spec.equal(log, { "a before", "b after", "b before" })
end)

Spec.test("Scheduler: a thread that throws is recorded and ended; others continue", function()
	const scheduler = Scheduler.new(1)
	local survived = false
	scheduler:spawn(function()
		scheduler:wait(1)
		error("boom", 0)
	end, "bad")
	scheduler:spawn(function()
		scheduler:wait(2)
		survived = true
	end, "good")
	scheduler:run()
	Spec.equal(#scheduler.failures, 1)
	Spec.equal(scheduler.failures[1].group, "bad")
	Spec.equal(scheduler.failures[1].message, "boom")
	Spec.equal(survived, true)
end)

Spec.test("Scheduler: a parked thread (wait forever) stops run without spinning", function()
	const scheduler = Scheduler.new(1)
	scheduler:spawn(function()
		scheduler:wait(math.huge)
	end, "hung")
	scheduler:run()
	Spec.equal(scheduler:count("hung"), 1)
	Spec.equal(scheduler:step(), false)
end)

Spec.test("Scheduler: misuse is refused", function()
	const scheduler = Scheduler.new(1)
	Spec.throws(function()
		scheduler:wait(1)
	end, "outside a scheduler thread")
	Spec.throws(function()
		scheduler:spawn(function() end)
	end, "needs a group")
	Spec.throws(function()
		Sim.run(scheduler, "s", function()
			scheduler:wait(-1)
		end)
	end, "delay >= 0")
end)

return nil
