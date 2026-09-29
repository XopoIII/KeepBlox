--!strict
--- One virtual server's view of time, over the shared scheduler.
---
--- Real servers do not agree on the time: `os.time()` differs between machines by the skew of their
--- clocks, and a clock can also run slightly fast or slow (drift). The library must never decide
--- anything by comparing its own clock with another server's, and this fake is how the harness
--- proves it: each server gets its own skew and drift.
---
--- `now()` is the server's monotonic clock (`os.clock`-like: seconds since the server started, never
--- stepping back). `time()` is its wall clock (`os.time`: whole Unix seconds, skewed and drifting).
--- Waiting always takes true scheduler time; a fast clock only reads differently, it does not make
--- the server run faster.
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

export type Options = {
	--> The group (server) that threads spawned from this clock belong to.
	group: string,
	--> Seconds this server's wall clock is ahead of true time (negative: behind). Default 0.
	skew: number?,
	--> Relative rate error: 0.001 runs 0.1% fast. Default 0.
	drift: number?,
	--> True Unix time at scheduler time 0. Default 1_800_000_000 (2027-01-15).
	epoch: number?,
}

const DEFAULT_EPOCH = 1_800_000_000

const Clock = {}

--> A clock for one server. `startedAt` is the scheduler time the server booted (its `now()` origin).
function Clock.new(scheduler: Scheduler.Scheduler, options: Options): Services.Clock
	const group = options.group
	const skew = options.skew or 0
	const rate = 1 + (options.drift or 0)
	const epoch = options.epoch or DEFAULT_EPOCH
	const startedAt = scheduler.now
	assert(rate > 0, "Clock drift must keep the clock running forward")

	local clock: Services.Clock = {
		now = function(): number
			return (scheduler.now - startedAt) * rate
		end,
		time = function(): number
			return math.floor(epoch + skew + scheduler.now * rate)
		end,
		wait = function(dt: number?): number
			return scheduler:wait(dt)
		end,
		-- As `task.spawn`: runs at once, up to the first yield.
		spawn = function(target: thread | (...any) -> (), ...: any)
			scheduler:resume(target, group, ...)
		end,
		cancel = function(target: thread)
			scheduler:cancel(target)
		end,
	}
	return clock
end

--> True Unix time in milliseconds for `scheduler`: what Roblox's services stamp records with
--> (`DataStoreKeyInfo.UpdatedTime`). Services run on Roblox's clock, not on any game server's.
function Clock.trueMillis(scheduler: Scheduler.Scheduler, epoch: number?): number
	return math.floor(((epoch or DEFAULT_EPOCH) + scheduler.now) * 1000)
end

return Clock
