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

return Call
