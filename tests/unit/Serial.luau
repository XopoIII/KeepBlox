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
