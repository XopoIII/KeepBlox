--!strict
--- One-at-a-time execution: calls through the same Serial run in order, never overlapping. Each
--- profile has one, so its autosave, a manual save and its release never race each other.
---
--- Each call runs in a thread the lane owns, and its caller only waits for the answer. A game may
--- cancel the caller (`task.cancel`, `coroutine.close`) at any moment, queued or in the middle of the
--- call: that ends the caller's wait and nothing else. The call still runs to its end in its turn,
--- and the lane passes on. Were the call run in the caller's own thread, a caller cancelled while its
--- write was in flight would keep the lane for good, and the session would never write again.
const Services = require("./Services")

export type Serial = {
	--> Runs `fn(...)` once every earlier call has finished; returns its results, or rethrows its error.
	run: (self: Serial, fn: (...any) -> ...any, ...any) -> ...any,
	--> Whether a call is running now.
	busy: (self: Serial) -> boolean,
}

const Serial = {}

--> `orphaned` is told the error of a call whose caller was cancelled meanwhile, so nobody is left to
--> rethrow it to. Without it the error is thrown in the lane's own thread, which the engine prints.
function Serial.new(clock: Services.Clock, orphaned: ((problem: any) -> ())?): Serial
	local busy = false
	const queue: { (...any) -> () } = {}

	const function release()
		const nextJob = table.remove(queue, 1)
		if nextJob == nil then
			busy = false
			return
		end
		-- The lock passes straight to the next call; `busy` stays true.
		clock.spawn(nextJob)
	end

	return {
		run = function(_: Serial, fn: (...any) -> ...any, ...: any): ...any
			const caller = coroutine.running()
			const args = table.pack(...)
			local results: { any }? = nil
			local waiting = false
			const job: (...any) -> () = function()
				const outcome = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
				results = outcome
				release()
				if not waiting then
					-- The call never yielded: the caller is still in `run` below and reads the results.
					return
				end
				if coroutine.status(caller) ~= "dead" then
					clock.spawn(caller)
				elseif not outcome[1] then
					-- The caller was cancelled while it waited, and the call failed: say so somewhere.
					if orphaned == nil then
						error(outcome[2], 0)
					end
					orphaned(outcome[2])
				end
			end
			if busy then
				table.insert(queue, job)
			else
				busy = true
				clock.spawn(job)
			end
			if results == nil then
				waiting = true
				coroutine.yield()
			end
			const outcome = results :: { any }
			if not outcome[1] then
				error(outcome[2], 0)
			end
			return table.unpack(outcome, 2, (outcome :: any).n)
		end,
		busy = function(_: Serial): boolean
			return busy
		end,
	}
end

return Serial
