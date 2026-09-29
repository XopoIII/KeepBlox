--!strict
--- The ledger: what every session did and what the data store committed, checked against the
--- guarantees (.claude/plan/02-guarantees.md) as it happens.
---
--- A simulated player's data is `{ p = { [tag] = steps } }`: each session has its own tag and counts
--- its steps of play there. So a save says exactly whose progress it holds, and a lost write shows up
--- as a count that went back, even when other sessions played on meanwhile. Sessions report to the
--- ledger (opening, opened, mutated, acked, ended); the backend reports every committed write.
--- Records are read through the adapter's `Format` (ProfileStore's record by default, which KeepBlox
--- keeps), so the same checks hold any library to the same guarantees.
---
--- Invariants (a breach is a violation, with the time and key):
--- - `ack-lost`: a session opened with less of some tag than an acknowledged save held when the open
---   started; or, at the end, the store holds less of some tag than was acknowledged (guarantee 1).
--- - `foreign-write`: `Data` changed in a write by a server that did not hold the lock in the version
---   it replaced (guarantee 2).
--- - `load-count-backwards`: `MetaData.SessionLoadCount` went down (guarantee 3).
---
--- Metrics (what the baseline is compared on): progress lost on reload, how long a replaced session
--- stayed active beside its successor, and how long opening took.
const Adapter = require("./Adapter")
const Backend = require("@fakes/Backend")
const Encoding = require("@fakes/Encoding")
const Scheduler = require("@fakes/Scheduler")

export type Violation = { invariant: string, at: number, key: string, detail: string }

type Counts = { [string]: number }

export type Metrics = {
	--> Most steps of one session that a reload did not have: played, minus what was loaded.
	maxProgressLost: number,
	--> Longest time a session stayed active after another server opened the same key.
	maxStaleSeconds: number,
	--> Longest time a successful open took.
	maxOpenSeconds: number,
	opens: number,
	failedOpens: number,
	--> Opens that ended because the player had already left: not a failure of the library.
	cancelledOpens: number,
	--> How long each successful open took, in order (the benchmarks take percentiles of it).
	openSeconds: { number },
}

export type Ledger = {
	read violations: { Violation },
	read metrics: Metrics,
	opening: (self: Ledger, key: string, server: string) -> (),
	opened: (self: Ledger, key: string, server: string, loaded: Counts) -> (),
	openFailed: (self: Ledger, key: string, server: string, cancelled: boolean?) -> (),
	mutated: (self: Ledger, key: string, tag: string, steps: number) -> (),
	acked: (self: Ledger, key: string, saved: Counts) -> (),
	ended: (self: Ledger, key: string, server: string) -> (),
	--> Every session of `server` ends at once (it crashed).
	crashed: (self: Ledger, server: string) -> (),
	--> The final check: what the store holds for every key against everything acknowledged.
	finish: (self: Ledger, backend: Backend.Backend, store: string, format: Adapter.Format?, world: any?) -> (),
}

type KeyState = {
	acked: Counts,
	played: Counts,
	openingSince: { [string]: { at: number, acked: Counts } },
	active: { [string]: boolean },
	--> When another server opened the key while this server's session was active.
	staleSince: { [string]: number },
}

const Ledger = {}

-- The first tag whose count in `have` is below `need`, with both counts; nil when none is.
const function shortfall(need: Counts, have: Counts): (string?, number, number)
	for tag, count in need do
		const held = have[tag] or 0
		if held < count then
			return tag, held, count
		end
	end
	return nil, 0, 0
end

--> `jobOf` maps a server name to the JobId it writes into `ActiveSession`.
function Ledger.new(scheduler: Scheduler.Scheduler, _jobOf: (server: string) -> string): Ledger
	const keys: { [string]: KeyState } = {}
	const violations: { Violation } = {}
	const metrics: Metrics = {
		maxProgressLost = 0,
		maxStaleSeconds = 0,
		maxOpenSeconds = 0,
		opens = 0,
		failedOpens = 0,
		cancelledOpens = 0,
		openSeconds = {},
	}

	const function state(key: string): KeyState
		local found = keys[key]
		if not found then
			found = { acked = {}, played = {}, openingSince = {}, active = {}, staleSince = {} }
			keys[key] = found
		end
		return found
	end

	const function violate(invariant: string, key: string, detail: string)
		table.insert(violations, { invariant = invariant, at = scheduler.now, key = key, detail = detail })
	end

	const function endSession(found: KeyState, server: string)
		found.active[server] = nil
		const since = found.staleSince[server]
		if since then
			metrics.maxStaleSeconds = math.max(metrics.maxStaleSeconds, scheduler.now - since)
			found.staleSince[server] = nil
		end
	end

	const self: Ledger = {
		violations = violations,
		metrics = metrics,

		opening = function(_: Ledger, key: string, server: string)
			const found = state(key)
			found.openingSince[server] = { at = scheduler.now, acked = table.clone(found.acked) }
		end,

		opened = function(_: Ledger, key: string, server: string, loaded: Counts)
			const found = state(key)
			const opening = found.openingSince[server]
			found.openingSince[server] = nil
			metrics.opens += 1
			if opening then
				metrics.maxOpenSeconds = math.max(metrics.maxOpenSeconds, scheduler.now - opening.at)
				table.insert(metrics.openSeconds, scheduler.now - opening.at)
				const tag, held, need = shortfall(opening.acked, loaded)
				if tag then
					violate("ack-lost", key, `{server} opened with {held} of {tag}, below the acknowledged {need}`)
				end
			end
			for tag, played in found.played do
				metrics.maxProgressLost = math.max(metrics.maxProgressLost, played - (loaded[tag] or 0))
			end
			for other in found.active do
				if other ~= server and not found.staleSince[other] then
					found.staleSince[other] = scheduler.now
				end
			end
			found.active[server] = true
		end,

		openFailed = function(_: Ledger, key: string, server: string, cancelled: boolean?)
			state(key).openingSince[server] = nil
			if cancelled then
				metrics.cancelledOpens += 1
			else
				metrics.failedOpens += 1
			end
		end,

		mutated = function(_: Ledger, key: string, tag: string, steps: number)
			const played = state(key).played
			played[tag] = math.max(played[tag] or 0, steps)
		end,

		acked = function(_: Ledger, key: string, saved: Counts)
			const acked = state(key).acked
			for tag, steps in saved do
				acked[tag] = math.max(acked[tag] or 0, steps)
			end
		end,

		ended = function(_: Ledger, key: string, server: string)
			endSession(state(key), server)
		end,

		crashed = function(_: Ledger, server: string)
			for _, found in keys do
				if found.active[server] then
					endSession(found, server)
				end
				found.openingSince[server] = nil
			end
		end,

		finish = function(_: Ledger, backend: Backend.Backend, store: string, format: Adapter.Format?, world: any?)
			const shape = format or Adapter.PROFILE_STORE
			for key, found in keys do
				local data: Adapter.Data? = nil
				if shape.current then
					data = shape.current(world, key)
				else
					const latest = backend:latest(store, key)
					data = if latest and not latest.deleted then shape.data(latest.value) else nil
				end
				const stored = if data then data.p else {}
				const tag, held, need = shortfall(found.acked, stored)
				if tag then
					violate("ack-lost", key, `the store ends with {held} of {tag}, below the acknowledged {need}`)
				end
			end
		end,
	}

	return self
end

--> Checks one committed write against the lock and load-count invariants. Wire it to
--> `backend:observe` for the store under test.
function Ledger.checkWrite(
	ledger: Ledger,
	scheduler: Scheduler.Scheduler,
	jobOf: (server: string) -> string,
	event: Backend.WriteEvent,
	format: Adapter.Format?
)
	const shape = format or Adapter.PROFILE_STORE
	const readLock = shape.lock
	const previous = event.previous
	const version = event.version
	if readLock == nil or previous == nil or previous.deleted or version.deleted or event.writer == nil then
		return
	end
	const before, after = previous.value, version.value
	if type(before) ~= "table" or type(after) ~= "table" then
		return
	end
	const record = function(invariant: string, detail: string)
		table.insert(
			ledger.violations :: { Violation },
			{ invariant = invariant, at = scheduler.now, key = event.key, detail = detail }
		)
	end
	const lockBefore, lockAfter = readLock(before), readLock(after)
	if Encoding.encode(shape.data(before)) ~= Encoding.encode(shape.data(after)) then
		const holder = lockBefore.job
		if holder == nil or holder ~= jobOf(event.writer :: string) then
			record("foreign-write", `{event.writer} changed Data while the lock was held by {holder or "nobody"}`)
		end
	end
	const countBefore = lockBefore.loadCount or 0
	const countAfter = lockAfter.loadCount or 0
	if countAfter < countBefore then
		record("load-count-backwards", `SessionLoadCount went from {countBefore} to {countAfter}`)
	end
end

return Ledger
