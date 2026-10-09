--!strict
--- The one-at-a-time lane behind each session's writes (src/Serial.luau).
const Serial = require("@keepblox/Serial")
const Clock = require("@fakes/Clock")
const Scheduler = require("@fakes/Scheduler")
const Sim = require("./Sim")
const Spec = require("../Spec")

const function rig(): (Serial.Serial, Scheduler.Scheduler)
	const scheduler = Scheduler.new(1)
	return Serial.new(Clock.new(scheduler, { group = "A" })), scheduler
end

Spec.test("Serial: calls run one at a time, in the order they arrived", function()
	const serial, scheduler = rig()
	const order = {}
	Sim.run(scheduler, "A", function()
		scheduler:spawn(function()
			serial:run(function()
				scheduler:wait(1)
				table.insert(order, "first")
			end)
		end)
		scheduler:wait(0.1) -- "first" holds the lane now
		scheduler:spawn(function()
			serial:run(function()
				table.insert(order, "second")
			end)
		end)
		table.insert(order, "body")
		scheduler:wait(5)
	end)
	Spec.equal(order, { "body", "first", "second" })
end)

Spec.test("Serial: a call that throws rethrows to its caller, and the lane goes on", function()
	const serial, scheduler = rig()
	const caught = Sim.catch(scheduler, "A", function()
		serial:run(function()
			error("boom", 0)
		end)
	end)
	Spec.equal(caught, "boom")
	local ran = false
	Sim.run(scheduler, "A", function()
		serial:run(function()
			ran = true
		end)
	end)
	Spec.equal(ran, true)
	Spec.equal(serial:busy(), false)
end)

Spec.test("Serial: a queued caller cancelled while waiting does not hold the lane", function()
	-- A game that spawned `profile:save()` may cancel its thread while the save waits in the lane.
	-- The dead thread can never run, so it can never free the lane: it must be skipped, or every
	-- later call queues behind a ghost and the session never saves again.
	const serial, scheduler = rig()
	const order = {}
	local queued: thread? = nil
	Sim.run(scheduler, "A", function()
		scheduler:spawn(function()
			serial:run(function()
				scheduler:wait(1)
				table.insert(order, "first")
			end)
		end)
		scheduler:wait(0.1) -- "first" holds the lane now
		scheduler:spawn(function()
			queued = coroutine.running()
			serial:run(function()
				table.insert(order, "cancelled")
			end)
		end)
		scheduler:wait(0.1) -- the second call is queued now
		scheduler:cancel(queued :: thread) -- the game went away
		scheduler:spawn(function()
			serial:run(function()
				table.insert(order, "third")
			end)
		end)
		scheduler:wait(5)
	end)
	Spec.equal(order, { "first", "third" })
	Spec.equal(serial:busy(), false)
end)

return nil
