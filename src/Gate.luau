--!strict
--- A server's load retries while its data store fails: one probe at a time instead of every load's.
---
--- A retry fired at a store that is down only fails, and spends the budget the loads need once it is
--- back: with one player's budget and 30 loads retrying through a minute's outage, the last of them
--- landed 18 s after the store was back, for want of requests (bench/Retry). So once the share of this
--- server's failing calls passes `OPEN`, a load's retry waits here after its own backoff. One of them
--- goes at a time, as the probe, `backoffMin` seconds after the last one failed; the probe that
--- answers lets every waiting load go at once.
---
--- A lone failing load is not slowed: it is its own probe, at its own backoff. A key that fails among
--- keys that work does not hold the others: first tries are never held, and one that answers closes the
--- gate.
const Services = require("./Services")

type State = {
	--> The share of recent calls that failed, each call weighing `WEIGHT`.
	failing: number,
	open: boolean,
	--> A probe is in flight.
	probing: boolean,
	--> When the next probe may go.
	nextProbe: number,
	--> Counts the probes that answered: a waiting load that sees it move goes at once.
	answered: number,
}

const Gate = {}

--> False turns the gate off: every retry goes at its own backoff. The benchmark measures against that.
Gate.enabled = true

const OPEN = 0.3
const WEIGHT = 0.2
const POLL = 0.25
-- A wait shorter than this is over: what float sums leave of a backoff must not stall the clock.
const TINY = 0.001

-- One state per server: every store of a server shares its budget, so they share the gate.
const states: { [Services.Services]: State } = setmetatable({}, { __mode = "k" }) :: any

const function stateOf(services: Services.Services): State
	local state = states[services]
	if not state then
		state = { failing = 0, open = false, probing = false, nextProbe = 0, answered = 0 }
		states[services] = state
	end
	return state
end

--> Records how a data store call ended. `probe`: the call was the one `Gate.wait` let through; the
--> next probe goes `every` seconds after one that failed.
function Gate.note(services: Services.Services, ok: boolean, probe: boolean, every: number)
	if not Gate.enabled then
		return
	end
	const state = stateOf(services)
	if probe then
		state.probing = false
	end
	if ok then
		if probe and state.open then
			state.answered += 1
		end
		state.failing = 0
		state.open = false
		return
	end
	state.failing = state.failing * (1 - WEIGHT) + WEIGHT
	if state.failing > OPEN and (probe or not state.open) then
		state.open = true
		state.nextProbe = services.clock.now() + every
	end
end

--> Whether the store is failing: a load's retry then waits in `Gate.wait`.
function Gate.open(services: Services.Services): boolean
	return Gate.enabled and stateOf(services).open
end

--> Gives the probe up when `probe`: the load that was let through ends without making its call.
function Gate.drop(services: Services.Services, probe: boolean)
	if probe then
		stateOf(services).probing = false
	end
end

--> Waits `least` seconds, or less when a probe answers meanwhile. Then, while the store still fails,
--> waits to be the probe, until `deadline` passes or `stop()` says so. Returns whether this thread's
--> next call is the probe: it is then told to `Gate.note`, or given up with `Gate.drop`.
function Gate.wait(services: Services.Services, least: number, deadline: number, stop: () -> boolean): boolean
	const state = stateOf(services)
	const clock = services.clock
	const answered = state.answered
	local left = least
	while clock.now() < deadline and not stop() do
		if state.answered ~= answered then
			return false
		elseif left < TINY then
			if not state.open then
				return false
			elseif clock.now() >= state.nextProbe and not state.probing then
				state.probing = true
				return true
			end
		end
		left -= clock.wait(math.min(POLL, deadline - clock.now(), if left >= TINY then left else POLL))
	end
	return false
end

return Gate
