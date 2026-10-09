--!strict
--- A call run apart from its caller (src/Apart.luau): what `store:load` and `profile:release()` stand
--- on, so that a caller the game cancels takes nothing with it.
const Apart = require("@keepblox/Apart")
const Clock = require("@fakes/Clock")
const Scheduler = require("@fakes/Scheduler")
const Sim = require("./Sim")
const Spec = require("../Spec")

const function rig(): (Scheduler.Scheduler, any, { any })
	const scheduler = Scheduler.new(1)
	const told: { any } = {}
	return scheduler, Clock.new(scheduler, { group = "A" }), told
end

Spec.test("Apart: a call that never yields answers in the caller's own turn, results whole", function()
	const scheduler, clock, told = rig()
	local results: { any } = {}
	local count = 0
	local turn = -1
	Sim.run(scheduler, "A", function()
		const before = scheduler:count()
		results = table.pack(Apart.run(clock, function(problem: any)
			table.insert(told, problem)
		end, function(a: number, b: nil, c: number): (number, nil, number)
			return c, b, a
		end, 1, nil, 2))
		count = results.n
		turn = scheduler:count() - before
	end)
	Spec.equal(count, 3)
	Spec.equal({ results[1], results[2], results[3] }, { 2, nil, 1 } :: { any })
	Spec.equal(turn, 0, "no thread is left behind")
	Spec.equal(told, {})
end)

Spec.test("Apart: the call starts at once, and its caller goes on in the turn the call ends in", function()
	const scheduler, clock, told = rig()
	const order: { string } = {}
	Sim.run(scheduler, "A", function()
		scheduler:resume(function()
			table.insert(order, "calling")
			const answer = Apart.run(clock, function(problem: any)
				table.insert(told, problem)
			end, function(): string
				table.insert(order, "started")
				scheduler:wait(1)
				table.insert(order, `done at {scheduler.now}`)
				return "answer"
			end)
			table.insert(order, `returned {answer} at {scheduler.now}`)
		end)
		-- The caller ran up to the call's first yield, and the call with it.
		table.insert(order, "body")
		scheduler:wait(5)
	end)
	Spec.equal(order, { "calling", "started", "body", "done at 1", "returned answer at 1" })
	Spec.equal(told, {})
end)

-- A call that parks for a second, then returns or throws; its caller is cancelled half a second in
-- when `cancel` is set. Returns what the caller caught, whether it went on, and when the call ended.
const function parked(
	scheduler: Scheduler.Scheduler,
	clock: any,
	told: { any },
	cancel: boolean,
	throws: boolean
): (string?, boolean, number?)
	local caller: thread? = nil
	local caught: string? = nil
	local wentOn = false
	local endedAt: number? = nil
	scheduler:spawn(function()
		caller = coroutine.running()
		const ok, problem = pcall(Apart.run, clock, function(orphaned: any)
			table.insert(told, orphaned)
		end, function()
			scheduler:wait(1)
			endedAt = scheduler.now
			if throws then
				error("boom", 0)
			end
		end)
		wentOn = true
		caught = if ok then nil else problem
	end, "A")
	const started = scheduler.now
	scheduler:run(started + 0.5)
	if cancel then
		scheduler:cancel(caller :: thread)
	end
	scheduler:run(started + 5)
	return caught, wentOn, if endedAt then endedAt - started else nil
end

Spec.test("Apart: a caller cancelled in the middle ends alone; the call runs to its end", function()
	const scheduler, clock, told = rig()
	const caught, wentOn, endedAfter = parked(scheduler, clock, told, true, false)
	Spec.equal(endedAfter, 1, "the call ended when it would have")
	Spec.equal(wentOn, false, "a cancelled caller never goes on")
	Spec.equal(caught, nil)
	Spec.equal(told, {}, "a call that ended well is nobody's news")
	Spec.equal(#scheduler.failures, 0, "and the dead caller was not woken")
	Spec.equal(scheduler:count(), 0, "no thread is left behind")
	-- A caller nobody cancels goes on, and hears nothing either.
	const caughtAlive, wentOnAlive, endedAfterAlive = parked(scheduler, clock, told, false, false)
	Spec.equal({ caughtAlive, wentOnAlive, endedAfterAlive } :: { any }, { nil, true, 1 } :: { any })
	Spec.equal(told, {})
end)

Spec.test("Apart: a call that throws rethrows to its caller, or is reported when the caller is gone", function()
	const scheduler, clock, told = rig()
	const caught, wentOn = parked(scheduler, clock, told, false, true)
	Spec.equal(caught, "boom")
	Spec.equal(wentOn, true)
	Spec.equal(told, {}, "a caller that heard the error is the only one told")
	const caughtGone, wentOnGone, endedAfter = parked(scheduler, clock, told, true, true)
	Spec.equal(caughtGone, nil)
	Spec.equal(wentOnGone, false)
	Spec.equal(endedAfter, 1)
	Spec.equal(told, { "boom" })
	Spec.equal(#scheduler.failures, 0)
	-- A call that throws without ever yielding throws in the caller's own turn.
	local thrown: string? = nil
	Sim.run(scheduler, "A", function()
		const _, problem = pcall(Apart.run, clock, function(orphaned: any)
			table.insert(told, orphaned)
		end, function()
			error("at once", 0)
		end)
		thrown = problem
	end)
	Spec.equal(thrown, "at once")
	Spec.equal(told, { "boom" })
end)

return nil
