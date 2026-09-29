--!strict
--- Virtual time and a seeded interleaving of every yield point.
---
--- Each simulated thread is a coroutine. A thread yields by waiting (`wait(dt)`, or `wait(0)` to let
--- others run); the fakes make every service call a wait, so every call is a point where another
--- server can act. `step()` wakes one thread: the earliest wake time wins, and among threads due at the
--- same moment the seeded generator picks. Time jumps straight to the next wake, so a 10-minute
--- scenario runs in milliseconds, and the same seed replays the same order exactly.
---
--- Threads belong to a group (a virtual server). `crash(group)` drops every thread of that group
--- where it stands, which is what a server crash looks like to everyone else: its calls stop at
--- whatever yield point they had reached. A thread that waits `math.huge` is parked for good (a hung
--- call): `run()` stops when only such threads are left.
const Prng = require("./Prng")

type Thread = {
	id: number,
	group: string,
	wakeAt: number,
	co: thread,
	args: { any },
	argc: number,
	started: boolean,
}

export type Failure = { group: string, thread: number, message: string }

export type Scheduler = {
	--> Virtual seconds since the scheduler was made. Only the scheduler moves it.
	now: number,
	read seed: number,
	--> Errors thrown by threads, in the order they were thrown. A thread that throws is ended.
	read failures: { Failure },
	--> The random source for fakes that need one (latency, faults), shared so one seed rules all.
	read random: Prng.Prng,
	--> Starts `fn(...)` as a new thread in `group`, or in the running thread's group. It first runs on
	--> a later `step`, never inside this call. Returns the thread's id.
	spawn: (self: Scheduler, fn: (...any) -> (), group: string?, ...any) -> number,
	--> Suspends the running thread for `dt` virtual seconds (0 is a pure yield). Returns the time slept.
	wait: (self: Scheduler, dt: number?) -> number,
	--> The group of the running thread, or nil outside any thread.
	currentGroup: (self: Scheduler) -> string?,
	--> Wakes one due thread. Returns false when no thread can wake.
	step: (self: Scheduler) -> boolean,
	--> Steps until no thread can wake, or until the next wake is past `untilTime` (time then stops
	--> exactly at `untilTime`). Returns the number of steps taken.
	run: (self: Scheduler, untilTime: number?) -> number,
	--> Drops every thread of `group` at its current yield point. Returns how many were dropped.
	crash: (self: Scheduler, group: string) -> number,
	--> How many threads are alive (parked ones included), in `group` or in total.
	count: (self: Scheduler, group: string?) -> number,
}

-- Guards `run` against a thread that waits 0 forever and would never let time move.
const MAX_STEPS_PER_RUN = 10_000_000

const Scheduler = {}

--> A scheduler at virtual time 0, ordered by `seed`.
function Scheduler.new(seed: number): Scheduler
	local threads: { Thread } = {}
	local nextId = 0
	local current: Thread? = nil
	const failures: { Failure } = {}
	const random = Prng.new(seed)

	-- The earliest wake time among live threads; math.huge when none can wake.
	const function nextWake(): number
		local earliest = math.huge
		for _, thread in threads do
			earliest = math.min(earliest, thread.wakeAt)
		end
		return earliest
	end

	const function spawn(self: Scheduler, fn: (...any) -> (), group: string?, ...: any): number
		const owner = group or (if current then current.group else nil)
		assert(owner, "Scheduler:spawn outside a thread needs a group")
		nextId += 1
		table.insert(threads, {
			id = nextId,
			group = owner,
			wakeAt = self.now,
			co = coroutine.create(fn),
			args = { ... },
			argc = select("#", ...),
			started = false,
		})
		return nextId
	end

	const function wait(self: Scheduler, dt: number?): number
		const running = current
		assert(running and coroutine.running() == running.co, "Scheduler:wait called outside a scheduler thread")
		const delay = dt or 0
		assert(delay >= 0, `Scheduler:wait needs a delay >= 0, got {delay}`)
		const started = self.now
		running.wakeAt = self.now + delay
		coroutine.yield()
		return self.now - started
	end

	const function currentGroup(_: Scheduler): string?
		return if current then current.group else nil
	end

	const function step(self: Scheduler): boolean
		const earliest = nextWake()
		if earliest == math.huge then
			return false
		end
		-- Threads are kept in spawn order, so the due list is the same for the same history.
		const due: { Thread } = {}
		for _, thread in threads do
			if thread.wakeAt == earliest then
				table.insert(due, thread)
			end
		end
		const chosen = due[random:integer(1, #due)]
		self.now = earliest

		current = chosen
		local ok: boolean, message: any
		if chosen.started then
			ok, message = coroutine.resume(chosen.co)
		else
			chosen.started = true
			ok, message = coroutine.resume(chosen.co, table.unpack(chosen.args, 1, chosen.argc))
		end
		current = nil

		if not ok then
			table.insert(failures, { group = chosen.group, thread = chosen.id, message = tostring(message) })
		end
		if not ok or coroutine.status(chosen.co) == "dead" then
			const index = table.find(threads, chosen)
			if index then
				table.remove(threads, index)
			end
		end
		return true
	end

	const function run(self: Scheduler, untilTime: number?): number
		local steps = 0
		while true do
			const wake = nextWake()
			if wake == math.huge or (untilTime ~= nil and wake > untilTime) then
				break
			end
			self:step()
			steps += 1
			assert(steps < MAX_STEPS_PER_RUN, "Scheduler:run made no progress: a thread keeps yielding without time")
		end
		if untilTime ~= nil and self.now < untilTime then
			self.now = untilTime
		end
		return steps
	end

	const function crash(_: Scheduler, group: string): number
		assert(
			not (current and current.group == group),
			"Scheduler:crash cannot crash the group of the running thread; crash it from the test body"
		)
		const kept: { Thread } = {}
		local dropped = 0
		for _, thread in threads do
			if thread.group == group then
				dropped += 1
			else
				table.insert(kept, thread)
			end
		end
		threads = kept
		return dropped
	end

	const function count(_: Scheduler, group: string?): number
		local total = 0
		for _, thread in threads do
			if group == nil or thread.group == group then
				total += 1
			end
		end
		return total
	end

	return {
		now = 0,
		seed = seed,
		failures = failures,
		random = random,
		spawn = spawn,
		wait = wait,
		currentGroup = currentGroup,
		step = step,
		run = run,
		crash = crash,
		count = count,
	}
end

return Scheduler
