--!strict
--- One-at-a-time execution: calls through the same Serial run in order, never overlapping. Each
--- profile has one, so its autosave, a manual save and its release never race each other.
const Services = require("./Services")

export type Serial = {
	--> Runs `fn(...)` once every earlier call has finished; returns its results, or rethrows its error.
	run: (self: Serial, fn: (...any) -> ...any, ...any) -> ...any,
	--> Whether a call is running now.
	busy: (self: Serial) -> boolean,
}

const Serial = {}

function Serial.new(clock: Services.Clock): Serial
	local busy = false
	const queue: { thread } = {}

	const function release()
		while true do
			const nextThread = table.remove(queue, 1)
			if nextThread == nil then
				busy = false
				return
			end
			-- A queued thread may be dead by its turn (the game cancelled it while it waited). It can
			-- never run, so it can never free the lane: skip it, or every later call queues behind a
			-- ghost and the session never saves again.
			if coroutine.status(nextThread) ~= "dead" then
				-- The lock passes straight to the next caller; `busy` stays true.
				clock.spawn(nextThread)
				return
			end
		end
	end

	return {
		run = function(_: Serial, fn: (...any) -> ...any, ...: any): ...any
			if busy then
				table.insert(queue, coroutine.running())
				coroutine.yield()
			else
				busy = true
			end
			const results = table.pack(pcall(fn, ...))
			release()
			if not results[1] then
				error(results[2], 0)
			end
			return table.unpack(results, 2, results.n)
		end,
		busy = function(_: Serial): boolean
			return busy
		end,
	}
end

return Serial
