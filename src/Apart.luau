--!strict
--- A call run apart from its caller: in a thread the library owns, while the caller only waits.
---
--- A game may cancel a thread that is inside `store:load` or `profile:release()` (`task.cancel`,
--- `coroutine.close`, or its script being destroyed). That ends the caller's wait and nothing else:
--- the call still runs to its end. Were it run in the caller's own thread, it would stop where it
--- stood: a load with its key marked as opening for good, a release between two tries of its final
--- write (issue 31). The write lane does the same for each write (see Serial).
const Services = require("./Services")

const Apart = {}

--> Runs `fn(...)` in a thread of its own and yields until it ends; returns its results, or rethrows
--> its error. `orphaned` is told the error of a call whose caller was cancelled meanwhile, so nobody
--> is left to rethrow it to.
function Apart.run(clock: Services.Clock, orphaned: (problem: any) -> (), fn: (...any) -> ...any, ...: any): ...any
	const caller = coroutine.running()
	const args = table.pack(...)
	local results: { any }? = nil
	local waiting = false
	clock.spawn(function()
		const outcome = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
		results = outcome
		if not waiting then
			-- The call never yielded: the caller is still in `run` below and reads the results.
			return
		end
		if coroutine.status(caller) ~= "dead" then
			clock.spawn(caller)
		elseif not outcome[1] then
			orphaned(outcome[2])
		end
	end)
	if results == nil then
		waiting = true
		coroutine.yield()
	end
	const outcome = results :: { any }
	if not outcome[1] then
		error(outcome[2], 0)
	end
	return table.unpack(outcome, 2, (outcome :: any).n)
end

return Apart
