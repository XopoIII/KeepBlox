--!strict
--- A game may cancel a thread that is inside `profile:release()`: often the thread of a player who
--- left. That ends the thread and nothing else. The final write is still retried until it is stored,
--- in a thread of the library's, so the key is freed without anyone calling the release again
--- (src/Open.luau, src/Apart.luau; issue 31).
const CancelRig = require("./CancelRig")
const Sim = require("./Sim")
const Spec = require("../Spec")

const stored = CancelRig.stored

type Rig = CancelRig.Rig

const REJECTED = "502: API Services rejected request"

type Held = {
	rig: Rig,
	profile: any,
	--> Every `onSaving(true, reason)` the profile fired, as "reason with coins".
	finals: { string },
	--> Every `onEnded(reason)`.
	ended: { string },
	--> How many writes of the key had landed, and requests were spent, once it was loaded.
	loaded: number,
	spent: number,
}

-- A session of "u_1" on A holding 7 coins the store has not seen.
const function held(options: { [string]: any }?): Held
	const rigged = CancelRig.new(options)
	local profile: any = nil
	Sim.run(rigged.world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		profile = result.profile
	end, 10)
	const finals: { string } = {}
	const ended: { string } = {}
	profile.onSaving:connect(function(final: boolean, reason: string?)
		if final then
			table.insert(finals, `{reason} with {profile.Data.coins}`)
		end
	end)
	profile.onEnded:connect(function(reason: string)
		table.insert(ended, reason)
	end)
	profile.Data.coins = 7
	return {
		rig = rigged,
		profile = profile,
		finals = finals,
		ended = ended,
		loaded = #rigged.log,
		spent = rigged.server.budget.spent.StandardWrite,
	}
end

-- Starts `profile:release()` in a thread of A, which runs at once up to its first yield. Returns the
-- thread and the table that says whether it went on, and what it threw.
const function release(session: Held): (thread, { returned: boolean, caught: any })
	const outcome = { returned = false, caught = nil :: any }
	local thread: thread? = nil
	session.rig.world.scheduler:resume(function()
		thread = coroutine.running()
		const ok, problem = pcall(session.profile.release, session.profile)
		outcome.returned = true
		outcome.caught = if ok then nil else problem
	end, "A")
	return thread :: thread, outcome
end

const function failOnce(session: Held)
	session.rig.world.faults:add({ op = "UpdateAsync", key = "u_1", error = REJECTED, times = 1 })
end

-- The key was freed by exactly two tries, the one that failed and its retry, holding the last play.
-- (A call the fake fails spends no budget: the failed try shows in the errors, the retry in the budget.)
const function freed(session: Held, label: string, failure: string?)
	const rigged = session.rig
	Spec.equal(stored(rigged.world).MetaData.ActiveSession, nil, `{label}: the key is free`)
	Spec.equal(stored(rigged.world).Data.coins, 7, `{label}: the last play is stored`)
	Spec.equal(#rigged.log, session.loaded + 1, `{label}: one write landed`)
	Spec.equal(rigged.log[session.loaded + 1], { coins = 7, held = false })
	Spec.equal(rigged.server.budget.spent.StandardWrite, session.spent + 1, `{label}: one retry`)
	Spec.equal(rigged.errors, { `u_1: save failed: {failure or REJECTED}` }, `{label}: the failure was reported once`)
	Spec.equal(session.finals, { "released with 7" }, `{label}: one final onSaving`)
	Spec.equal(session.ended, { "released" }, `{label}: one onEnded`)
	Spec.equal(session.profile:isActive(), false)
	Spec.equal(next(rigged.store:profiles()), nil, `{label}: no profile is open`)
end

Spec.test(
	"Cancelled release: its caller cancelled at every point, its write failing once, it still frees the key",
	function()
		local steps = 0
		local between, retrying = 0, 0
		while true do
			const session = held()
			const rigged = session.rig
			const scheduler = rigged.world.scheduler
			failOnce(session)
			const started = scheduler.now
			const caller, outcome = release(session)
			for _ = 1, steps do
				scheduler:step()
			end
			if outcome.returned then
				-- The release nobody cancelled: the same two requests, and its caller went on.
				Spec.equal(outcome.caught, nil)
				freed(session, "nobody cancelled")
				break
			end
			assert(steps < 200, "the release never returned")
			const label = `cancelled after {steps} steps`
			-- The fake fails the first try at once, so the release is between its two tries (`backoffMin`,
			-- one second) or has its second in flight.
			Spec.equal(#rigged.errors, 1, `{label}: the first try has failed`)
			if scheduler.now - started < 1 then
				between += 1
			else
				retrying += 1
			end
			scheduler:cancel(caller)
			-- Nobody calls the release again, and nothing else would: no renewal is due for 20 seconds.
			scheduler:run(started + 3)
			Spec.equal(outcome.returned, false, `{label}: the cancelled caller never went on`)
			freed(session, label)
			-- The key is this server's to load again.
			Sim.run(scheduler, "A", function()
				const again = rigged.store:load("u_1")
				assert(again.ok, `{label}: loaded again ({(again :: any).reason})`)
				Spec.equal(again.profile.Data.coins, 7)
				again.profile:release()
			end, scheduler.now + 60)
			Spec.equal(#scheduler.failures, 0)
			steps += 1
		end
		Spec.equal(between >= 1, true, `{between} cancels between the two tries`)
		Spec.equal(retrying >= 1, true, `{retrying} cancels with the retry in flight`)
	end
)

Spec.test("Cancelled release: cancelled with its first write lost in flight, it retries after the deadline", function()
	const session = held()
	const scheduler = session.rig.world.scheduler
	session.rig.world.faults:add({ op = "UpdateAsync", key = "u_1", hang = true, times = 1 })
	const started = scheduler.now
	local at = -1
	session.profile.onEnded:connect(function()
		at = scheduler.now - started
	end)
	const caller, outcome = release(session)
	Spec.equal(session.rig.errors, {}, "the write is in flight")
	scheduler:cancel(caller)
	scheduler:run(started + 19)
	Spec.equal(session.profile:isActive(), false)
	Spec.equal(session.ended, {}, "still waiting for the lost write's deadline (callTimeout, 20 s)")
	scheduler:run(started + 30)
	Spec.equal(outcome.returned, false)
	freed(session, "lost in flight", "timeout")
	-- The deadline, `backoffMin`, and the retry's own 0.05 to 0.25 s.
	Spec.equal(at > 21 and at < 21.3, true, `freed after {at} s`)
end)

Spec.test("Cancelled release: a release nobody cancels runs as it did, for the same requests", function()
	const session = held()
	const rigged = session.rig
	const scheduler = rigged.world.scheduler
	const profile = session.profile
	-- It starts in the caller's own turn: the game is told and the data frozen before the call yields.
	const _, first = release(session)
	Spec.equal(session.finals, { "released with 7" })
	Spec.equal(profile:isActive(), false)
	Spec.equal(table.isfrozen(profile.Data), true)
	Spec.equal(session.ended, {}, "not ended before the write lands")
	Spec.equal(first.returned, false)
	Spec.equal(#rigged.log, session.loaded, "the write is in flight, not landed")
	-- A second release of the same profile meanwhile waits for the same end, and writes nothing.
	const _, second = release(session)
	Spec.equal(second.returned, false)
	const started = scheduler.now
	local order: { string } = {}
	profile.onEnded:connect(function()
		table.insert(order, `ended, first returned: {first.returned}`)
	end)
	scheduler:run(started + 5)
	Spec.equal(first, { returned = true, caught = nil })
	Spec.equal(second, { returned = true, caught = nil })
	Spec.equal(order, { "ended, first returned: false" }, "the game hears the end before the release returns")
	Spec.equal(#rigged.log, session.loaded + 1)
	Spec.equal(rigged.log[session.loaded + 1], { coins = 7, held = false })
	Spec.equal(rigged.server.budget.spent.StandardWrite, session.spent + 1, "one request")
	Spec.equal(session.finals, { "released with 7" })
	Spec.equal(session.ended, { "released" })
	Spec.equal(rigged.errors, {})
	-- A release of a profile that has ended answers at once, and asks for nothing.
	const _, late = release(session)
	Spec.equal(late, { returned = true, caught = nil })
	Spec.equal(rigged.server.budget.spent.StandardWrite, session.spent + 1)
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Cancelled release: a failing write is retried after the same backoff, caller or none", function()
	-- When the key came free, measured from the release: with a caller that waits, and with one
	-- cancelled at once.
	const function freedAfter(cancel: boolean): number
		const session = held()
		const scheduler = session.rig.world.scheduler
		failOnce(session)
		const started = scheduler.now
		local at = -1
		session.profile.onEnded:connect(function()
			at = scheduler.now - started
		end)
		const caller = release(session)
		if cancel then
			scheduler:cancel(caller)
		end
		scheduler:run(started + 10)
		freed(session, if cancel then "cancelled" else "waited")
		return at
	end
	const waited = freedAfter(false)
	-- One failed call, `backoffMin` (1 s), one call: each call takes 0.05 to 0.25 s.
	Spec.equal(waited > 1.1 and waited < 1.5, true, `freed after {waited} s`)
	Spec.equal(freedAfter(true), waited, "the cancelled caller's release kept the same time")
end)

Spec.test("Cancelled release: a release that throws reaches its caller, or the store when it has none", function()
	-- A compressing store whose codec can be broken: the one step of a write that throws.
	const function broken(cancel: boolean): (Held, { returned: boolean, caught: any })
		const session = held({ template = { coins = 0, text = string.rep("a", 500) }, compress = { above = 100 } })
		const rigged = session.rig
		Sim.run(rigged.world.scheduler, "A", function()
			-- A save holds the lane, so the release parks behind it before it meets the broken codec.
			rigged.save(session.profile, "holder")
			rigged.codec.broken = true
			session.profile.Data.coins = 8
			const caller, outcome = release(session)
			Spec.equal(outcome.returned, false, "the release is parked")
			if cancel then
				rigged.world.scheduler:cancel(caller)
			end
			rigged.world.scheduler:wait(5)
			session.rig.answers.outcome = outcome :: any
		end, rigged.world.scheduler.now + 10)
		return session, (rigged.answers :: any).outcome
	end
	const heard, outcome = broken(false)
	Spec.equal(outcome, { returned = true, caught = "the codec is down" })
	Spec.equal(heard.rig.errors, {}, "a caller that heard the error is the only one told")
	const orphaned, gone = broken(true)
	Spec.equal(gone, { returned = false, caught = nil })
	Spec.equal(orphaned.rig.errors, { "u_1: a release failed after its caller was cancelled: the codec is down" })
	Spec.equal(#orphaned.rig.world.scheduler.failures, 0)
	-- The session is still there to be released once the codec is back: the shutdown does it.
	orphaned.rig.codec.broken = false
	Sim.run(orphaned.rig.world.scheduler, "A", function()
		orphaned.rig.server.closing[1]()
	end, orphaned.rig.world.scheduler.now + 30)
	Spec.equal(stored(orphaned.rig.world).MetaData.ActiveSession, nil)
	Spec.equal(orphaned.rig.log[#orphaned.rig.log], { coins = 8, held = false })
	Spec.equal(orphaned.ended, { "shutdown" })
end)

Spec.test("Cancelled release: shutdown waits for a release whose caller was cancelled", function()
	for _, pause in { 0, 0.5 } do
		const session = held()
		const rigged = session.rig
		const scheduler = rigged.world.scheduler
		failOnce(session)
		Sim.run(scheduler, "A", function()
			scheduler:cancel((release(session)))
			-- At once, with the failing write in flight; or half a second in, between the two tries.
			scheduler:wait(pause)
			const started = scheduler.now
			rigged.server.closing[1]()
			Spec.equal(scheduler.now > started, true, "the close waited")
			Spec.equal(scheduler.now - started < 3, true, "and not for its deadline")
			Spec.equal(stored(rigged.world).MetaData.ActiveSession, nil, "the key was free when the close returned")
			Spec.equal(stored(rigged.world).Data.coins, 7)
		end, scheduler.now + 60)
		Spec.equal(#rigged.log, session.loaded + 1)
		Spec.equal(session.finals, { "released with 7" })
		Spec.equal(#session.ended, 1)
		Spec.equal(session.profile:isActive(), false)
	end
end)

return nil
