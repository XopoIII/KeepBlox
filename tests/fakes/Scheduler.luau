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
	--> a later `step`, never inside this call (`task.defer`). Returns the thread's id.
	spawn: (self: Scheduler, fn: (...any) -> (), group: string?, ...any) -> number,
	--> Runs `fn` or resumes a thread at once, until it first yields (`task.spawn`, and the engine's
	--> `coroutine.resume`). A thread it has not seen joins `group`, or the running thread's group.
	--> Returns what `coroutine.resume` returns. A thread that yields without waiting is parked: only
	--> another `resume` wakes it.
	resume: (self: Scheduler, target: thread | (...any) -> (), group: string?, ...any) -> ...any,
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
	--> Forgets `co` (`task.cancel`, `coroutine.close`): it never wakes again.
	cancel: (self: Scheduler, co: thread) -> (),
	--> `coroutine.wrap` over the scheduler: each call resumes one thread as `resume` does, and an error
	--> goes to the caller instead of the failure list.
	wrap: (self: Scheduler, fn: (...any) -> ...any) -> (...any) -> ...any,
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

	const byCo: { [thread]: Thread } = {}

	const function track(co: thread, group: string?, wakeAt: number): Thread
		const owner = group or (if current then current.group else nil)
		assert(owner, "a thread started outside any thread needs a group")
		nextId += 1
		const record: Thread = {
			id = nextId,
			group = owner,
			wakeAt = wakeAt,
			co = co,
			args = {},
			argc = 0,
			started = false,
		}
		table.insert(threads, record)
		byCo[co] = record
		return record
	end

	const function forget(record: Thread)
		const index = table.find(threads, record)
		if index then
			table.remove(threads, index)
		end
		byCo[record.co] = nil
	end

	-- Resumes `record` with `record` as the running thread, and puts the previous one back after.
	-- A thread that yields without `wait` leaves wakeAt at math.huge: it is parked.
	const function resumeRecord(record: Thread, quiet: boolean, ...: any): ...any
		const previous = current
		current = record
		record.wakeAt = math.huge
		const results = table.pack(coroutine.resume(record.co, ...))
		current = previous
		if not results[1] then
			-- A quiet resume hands the error to its caller (`coroutine.wrap`), who decides.
			if not quiet then
				table.insert(failures, { group = record.group, thread = record.id, message = tostring(results[2]) })
			end
			forget(record)
		elseif coroutine.status(record.co) == "dead" then
			forget(record)
		end
		return table.unpack(results, 1, results.n)
	end

	const function spawn(self: Scheduler, fn: (...any) -> (), group: string?, ...: any): number
		const record = track(coroutine.create(fn), group, self.now)
		record.args = { ... }
		record.argc = select("#", ...)
		return record.id
	end

	const function resume(_: Scheduler, target: thread | (...any) -> (), group: string?, ...: any): ...any
		local record: Thread
		if type(target) == "thread" then
			record = byCo[target] or track(target, group, math.huge)
		else
			record = track(coroutine.create(target), group, math.huge)
		end
		if coroutine.status(record.co) ~= "suspended" then
			return false, `cannot resume {coroutine.status(record.co)} coroutine`
		end
		record.started = true
		return resumeRecord(record, false, ...)
	end

	const function wait(self: Scheduler, dt: number?): number
		const running = current
		assert(running and coroutine.running() == running.co, "Scheduler:wait called outside a scheduler thread")
		const delay = dt or 0
		assert(delay >= 0, `Scheduler:wait needs a delay >= 0, got {delay}`)
		const started = self.now
		-- resumeRecord parked the thread before resuming it; waiting replaces that with a wake time.
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
		if chosen.started then
			resumeRecord(chosen, false)
		else
			chosen.started = true
			resumeRecord(chosen, false, table.unpack(chosen.args, 1, chosen.argc))
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
				byCo[thread.co] = nil
			else
				table.insert(kept, thread)
			end
		end
		threads = kept
		return dropped
	end

	const function cancel(_: Scheduler, co: thread)
		const record = byCo[co]
		if record then
			forget(record)
		end
		-- task.cancel kills the thread, not only its wake-ups: a later resume must find it dead
		-- (https://create.roblox.com/docs/reference/engine/libraries/task#cancel).
		if coroutine.status(co) == "suspended" then
			coroutine.close(co)
		end
	end

	const function wrap(_: Scheduler, fn: (...any) -> ...any): (...any) -> ...any
		const co = coroutine.create(fn)
		return function(...: any): ...any
			if coroutine.status(co) ~= "suspended" then
				error(`cannot resume {coroutine.status(co)} coroutine`, 2)
			end
			const record = byCo[co] or track(co, nil, math.huge)
			record.started = true
			const results = table.pack(resumeRecord(record, true, ...))
			if not results[1] then
				error(results[2], 0)
			end
			return table.unpack(results, 2, results.n)
		end
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
		resume = resume,
		wait = wait,
		currentGroup = currentGroup,
		step = step,
		run = run,
		crash = crash,
		cancel = cancel,
		wrap = wrap,
		count = count,
	}
end

return Scheduler
