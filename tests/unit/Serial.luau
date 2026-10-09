--!strict
--- The one-at-a-time lane behind each session's writes (src/Serial.luau).
const KeepBlox = require("@keepblox")
const Serial = require("@keepblox/Serial")
const Clock = require("@fakes/Clock")
const Scheduler = require("@fakes/Scheduler")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

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

Spec.test("Serial: a caller's results come back whole, and it wakes after the next call has started", function()
	const serial, scheduler = rig()
	const order: { string } = {}
	local count, results = 0, {} :: { any }
	Sim.run(scheduler, "A", function()
		scheduler:spawn(function()
			results = table.pack(serial:run(function(a: number, b: number): (number, nil, number)
				scheduler:wait(1)
				table.insert(order, "first done")
				return a, nil, b
			end, 1, 2))
			count = results.n
			table.insert(order, "first returned")
		end)
		scheduler:wait(0.1) -- "first" holds the lane now
		scheduler:spawn(function()
			serial:run(function()
				table.insert(order, "second started")
				scheduler:wait(1)
			end)
			table.insert(order, "second returned")
		end)
		scheduler:wait(5)
	end)
	-- The lane passes on before the caller goes on, as when the call ran in the caller's own thread.
	Spec.equal(order, { "first done", "second started", "first returned", "second returned" })
	Spec.equal(count, 3)
	Spec.equal({ results[1], results[2], results[3] }, { 1, nil, 2 } :: { any })
	Spec.equal(serial:busy(), false)
end)

Spec.test("Serial: a queued caller cancelled while waiting neither holds the lane nor loses its call", function()
	-- A game that spawned `profile:save()` may cancel its thread while the save waits in the lane.
	-- That ends the caller's wait and nothing else: the call still runs in its turn, and the lane goes on.
	const serial, scheduler = rig()
	const order = {}
	local queued: thread? = nil
	local returned = false
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
			returned = true
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
	Spec.equal(order, { "first", "cancelled", "third" })
	Spec.equal(returned, false, "a cancelled caller never goes on")
	Spec.equal(serial:busy(), false)
end)

Spec.test("Serial: a caller cancelled in the middle of its call does not keep the lane", function()
	-- The call is parked in a yield (a write in flight) when the game cancels its caller. The call
	-- runs in the lane's thread, so it ends as it would have, and the calls behind it get their turn.
	const serial, scheduler = rig()
	const order = {}
	local holder: thread? = nil
	local returned = false
	Sim.run(scheduler, "A", function()
		scheduler:spawn(function()
			holder = coroutine.running()
			serial:run(function()
				table.insert(order, "first started")
				scheduler:wait(1)
				table.insert(order, `first done at {scheduler.now}`)
			end)
			returned = true
		end)
		scheduler:wait(0.5) -- "first" is parked inside its call
		Spec.equal(serial:busy(), true)
		scheduler:cancel(holder :: thread)
		scheduler:spawn(function()
			serial:run(function()
				table.insert(order, `second at {scheduler.now}`)
			end)
			table.insert(order, "second returned")
		end)
		scheduler:wait(5)
	end)
	Spec.equal(order, { "first started", "first done at 1", "second at 1", "second returned" })
	Spec.equal(returned, false, "a cancelled caller never goes on")
	Spec.equal(serial:busy(), false)
end)

-- A call that throws one second in; its caller is cancelled half a second in when `cancel` is set.
const function orphan(serial: Serial.Serial, scheduler: Scheduler.Scheduler, cancel: boolean): string?
	local caller: thread? = nil
	local caught: string? = nil
	scheduler:spawn(function()
		caller = coroutine.running()
		const _, problem = pcall(serial.run, serial, function()
			scheduler:wait(1)
			error("boom", 0)
		end)
		caught = problem
	end, "A")
	scheduler:run(scheduler.now + 0.5)
	if cancel then
		scheduler:cancel(caller :: thread)
	end
	scheduler:run(scheduler.now + 5)
	return caught
end

Spec.test("Serial: a call that throws after its caller was cancelled is reported, never dropped", function()
	const scheduler = Scheduler.new(1)
	const told = {}
	const serial = Serial.new(Clock.new(scheduler, { group = "A" }), function(problem: any)
		table.insert(told, problem)
	end)
	Spec.equal(orphan(serial, scheduler, true), nil)
	Spec.equal(told, { "boom" })
	Spec.equal(#scheduler.failures, 0)
	Spec.equal(serial:busy(), false)
	-- A caller that is still there gets the error itself, and nobody else is told.
	Spec.equal(orphan(serial, scheduler, false), "boom")
	Spec.equal(told, { "boom" })
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Serial: with nobody to tell, a cancelled caller's failed call fails the lane's own thread", function()
	-- As an error in any `task.spawn`ed thread: the engine prints it. Here the scheduler records it.
	const serial, scheduler = rig()
	Spec.equal(orphan(serial, scheduler, true), nil)
	Spec.equal(#scheduler.failures, 1)
	Spec.equal(scheduler.failures[1].message, "boom")
	Spec.equal(scheduler.failures[1].group, "A")
	Spec.equal(serial:busy(), false)
	-- A call whose caller is there to hear the error fails nothing else.
	Spec.equal(orphan(serial, scheduler, false), "boom")
	Spec.equal(#scheduler.failures, 1)
end)

Spec.test("Serial: a save's joined caller cancelled while waiting does not cost the others their answer", function()
	-- Manual saves that arrive while one is queued share its write (src/Session.luau). One of them is
	-- cancelled by the game meanwhile: it is passed over, and the rest still hear how the save went.
	const world = World.new(1)
	const store =
		KeepBlox.store("Profiles", { template = { coins = 0 }, services = world:server({ name = "A" }).services })
	const answers: { [string]: boolean } = {}
	local joined: thread? = nil
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const function save(name: string): (...any) -> ()
			const function body()
				if name == "joined, cancelled" then
					joined = coroutine.running()
				end
				answers[name] = profile:save()
			end
			return body :: any
		end
		profile.Data.coins = 7
		-- Each runs at once up to its first yield: the first holds the lane inside its write, the
		-- second queues behind it, and the other two join the second.
		world.scheduler:resume(save("holder"))
		world.scheduler:resume(save("queued"))
		world.scheduler:resume(save("joined, cancelled"))
		world.scheduler:resume(save("joined"))
		Spec.equal(answers, {})
		world.scheduler:cancel(joined :: thread)
		world.scheduler:wait(30)
		profile:release()
	end, 120)
	-- The cancelled caller never answered; every other one did, with the save's result.
	Spec.equal(answers, { holder = true, queued = true, joined = true })
	const latest = world.backend:latest("Profiles/global", "u_1")
	assert(latest, "stored")
	Spec.equal(latest.value.Data.coins, 7)
end)

return nil
