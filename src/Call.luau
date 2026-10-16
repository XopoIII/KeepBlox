--!strict
--- One data store call with a deadline. A call can hang (a request lost in flight), and nothing may
--- wait on it forever (guarantee 12). The call runs in its own thread, and the caller waits for
--- whichever comes first, its result or the deadline. A call that times out may still complete later,
--- so a write that timed out is treated like any failed write: it may or may not have happened.
const Services = require("./Services")

const Call = {}

--> Runs `fn(...)` for at most `timeout` seconds. Returns true and its results, or false and an error
--> ("timeout" when the deadline passed).
function Call.run(clock: Services.Clock, timeout: number, fn: (...any) -> ...any, ...: any): (boolean, ...any)
	const waiter = coroutine.running()
	local results: { any }? = nil
	local waiting = false
	local finished = false

	const function wake(outcome: { any })
		if finished then
			return
		end
		finished = true
		results = outcome
		if waiting then
			clock.spawn(waiter)
		end
	end

	const args = table.pack(...)
	clock.spawn(function()
		wake(table.pack(pcall(fn, table.unpack(args, 1, args.n))))
	end)
	-- The deadline, cancelled once the call answers: no thread sleeps on for a call long done.
	local deadline: thread? = nil
	if not finished then
		deadline = coroutine.create(function()
			clock.wait(timeout)
			wake(table.pack(false, "timeout"))
		end)
		clock.spawn(deadline :: thread)
	end
	if not finished then
		waiting = true
		coroutine.yield()
	end
	if deadline and coroutine.status(deadline) == "suspended" then
		clock.cancel(deadline)
	end
	const outcome = results :: { any }
	return table.unpack(outcome, 1, (outcome :: any).n)
end

--> `transform`, made to tell whether its last run finished. The engine swallows an UpdateAsync
--> transform that throws or yields: the call answers nil, nil, as if the transform had changed nothing
--> (live check 2026-10-16). `broken()` is then the reason; nil when the last run returned.
function Call.guard(transform: Services.Transform): (Services.Transform, () -> string?)
	local broken: string? = nil
	const function guarded(...: any): ...any
		broken = "the transform did not finish"
		const outcome = table.pack(pcall(transform, ...))
		if not outcome[1] then
			broken = `the transform failed: {tostring(outcome[2])}`
			return nil
		end
		broken = nil
		return table.unpack(outcome, 2, outcome.n)
	end
	return guarded :: any, function(): string?
		return broken
	end
end

--> `store:UpdateAsync(key, transform)` for at most `timeout` seconds, as `run`. A transform that threw
--> (or yielded) fails the call with its reason, as a failed write does: nothing was written.
function Call.update(
	clock: Services.Clock,
	timeout: number,
	store: Services.DataStore,
	key: string,
	transform: Services.Transform
): (boolean, ...any)
	const guarded, broken = Call.guard(transform)
	const results = table.pack(Call.run(clock, timeout, store.UpdateAsync, store, key, guarded))
	const reason = broken()
	if results[1] and reason then
		return false, reason
	end
	return table.unpack(results, 1, results.n)
end

return Call
