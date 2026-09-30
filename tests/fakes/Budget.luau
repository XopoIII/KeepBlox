--!strict
--- One server's data store request budget, per request type.
---
--- Source: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
--- - Per-server limits, per minute: StandardRead and StandardWrite 60 + players x 40, StandardList
---   5 + players x 2, StandardRemove 60 + players x 40; OrderedRead 60 + players x 40, OrderedWrite and
---   OrderedRemove 30 + players x 5, OrderedList 5 + players x 2. UpdateAsync "consumes from both the read and
---   write request budgets".
--- - Over budget, a request waits in its queue; "Each queue has a limit of 30 requests. When the limit of
---   a queue is reached, requests fail with an error code in the 301-306 range".
---
--- Measured live (a Studio play server with one player, 2026-09-30; the docs mention a startup burst
--- without a size): the budget refills continuously at the documented rates; a new server starts with
--- the burst in START; and nothing caps it (after 18 minutes it held 1767 writes, still growing by the
--- rate). How the burst scales with players was not measured: here it does not.
const Errors = require("./Errors")
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

type RequestType = Services.RequestType

export type Budget = {
	--> Players on this server; the rates scale with it.
	players: number,
	--> Requests spent so far, per type: what a library costs (the benchmarks read it).
	read spent: { [RequestType]: number },
	--> Whole requests of `requestType` that could go now.
	available: (self: Budget, requestType: RequestType) -> number,
	--> Takes one request from each of `types`, waiting in `queue` while any is short. Throws
	--> `queueFullError` at once when `queue` already holds 30 waiting requests.
	acquire: (self: Budget, types: { RequestType }, queue: string, queueFullError: string) -> (),
	--> How many requests wait in `queue` now.
	waiting: (self: Budget, queue: string) -> number,
}

const QUEUE_LIMIT = 30

const RATES: { [RequestType]: { base: number, perPlayer: number } } = {
	StandardRead = { base = 60, perPlayer = 40 },
	StandardWrite = { base = 60, perPlayer = 40 },
	StandardList = { base = 5, perPlayer = 2 },
	StandardRemove = { base = 60, perPlayer = 40 },
	OrderedRead = { base = 60, perPlayer = 40 },
	OrderedWrite = { base = 30, perPlayer = 5 },
	OrderedList = { base = 5, perPlayer = 2 },
	OrderedRemove = { base = 30, perPlayer = 5 },
}

-- What a new server holds of each type (live, one player).
const START: { [RequestType]: number } = {
	StandardRead = 600,
	StandardWrite = 600,
	StandardList = 35,
	StandardRemove = 600,
	OrderedRead = 600,
	OrderedWrite = 120,
	OrderedList = 35,
	OrderedRemove = 120,
}

const Budget = {}

--> The experience's own limit, shared by all its servers (error-codes-and-limits, "Experience-level
--> limits"): per minute, 300 + concurrent users x 40 reads, x 20 writes, x 2 lists, x 40 removes, the
--> same for ordered stores. Live (2026-09-30) a Studio server over it logged both
--> "StandardReadExperienceThrottled: ... request was throttled by experience limits" and "... rate
--> exceeds the allowed maximum": whether a request over it waits or fails is not known, so the fake
--> refuses it as unmodelled. Assumed: a minute's worth at most, full at the start.
export type Experience = {
	take: (self: Experience, types: { RequestType }) -> (),
}

const EXPERIENCE_PER_USER: { [RequestType]: number } = {
	StandardRead = 40,
	StandardWrite = 20,
	StandardList = 2,
	StandardRemove = 40,
	OrderedRead = 40,
	OrderedWrite = 20,
	OrderedList = 2,
	OrderedRemove = 40,
}

function Budget.experience(scheduler: Scheduler.Scheduler, users: () -> number): Experience
	const tokens: { [RequestType]: number } = {}
	local refilledAt = scheduler.now
	const function rate(requestType: RequestType): number
		return 300 + EXPERIENCE_PER_USER[requestType] * users()
	end
	return {
		take = function(_: Experience, types: { RequestType })
			const elapsed = scheduler.now - refilledAt
			refilledAt = scheduler.now
			for requestType in EXPERIENCE_PER_USER do
				const cap = rate(requestType)
				tokens[requestType] = math.min(cap, (tokens[requestType] or cap) + elapsed * cap / 60)
			end
			for _, requestType in types do
				if tokens[requestType] < 1 then
					error(Errors.unmodelled(`{requestType} over the experience's {rate(requestType)} a minute`), 0)
				end
			end
			for _, requestType in types do
				tokens[requestType] -= 1
			end
		end,
	}
end

--> `empty`: start with nothing, for specs that must see throttling at once. `experience`: the limit
--> this server shares with the others.
function Budget.new(scheduler: Scheduler.Scheduler, players: number?, empty: boolean?, experience: Experience?): Budget
	const tokens: { [RequestType]: number } = {}
	const queues: { [string]: number } = {}
	const spent: { [RequestType]: number } = {}
	local refilledAt = scheduler.now

	const function perMinute(self: Budget, requestType: RequestType): number
		const rate = RATES[requestType]
		return rate.base + rate.perPlayer * self.players
	end

	const function refill(self: Budget)
		const elapsed = scheduler.now - refilledAt
		refilledAt = scheduler.now
		for requestType in RATES do
			const start = if empty then 0 else START[requestType]
			tokens[requestType] = (tokens[requestType] or start) + elapsed * perMinute(self, requestType) / 60
		end
	end

	-- Seconds until every type in `types` holds a whole request, from the current refill rates.
	const function shortfall(self: Budget, types: { RequestType }): number
		local longest = 0
		for _, requestType in types do
			const missing = 1 - tokens[requestType]
			if missing > 0 then
				longest = math.max(longest, missing * 60 / perMinute(self, requestType))
			end
		end
		return longest
	end

	const self: Budget = {
		players = players or 0,
		spent = spent,

		available = function(budget: Budget, requestType: RequestType): number
			refill(budget)
			return math.floor(tokens[requestType])
		end,

		acquire = function(budget: Budget, types: { RequestType }, queue: string, queueFullError: string)
			refill(budget)
			if shortfall(budget, types) > 0 then
				const depth = queues[queue] or 0
				if depth >= QUEUE_LIMIT then
					error(queueFullError, 0)
				end
				queues[queue] = depth + 1
				while true do
					const delay = shortfall(budget, types)
					if delay <= 0 then
						break
					end
					-- At least a millisecond: a float remainder of a token must not stall virtual time.
					scheduler:wait(math.max(delay, 0.001))
					refill(budget)
				end
				queues[queue] -= 1
			end
			if experience then
				experience:take(types)
			end
			for _, requestType in types do
				tokens[requestType] -= 1
				spent[requestType] = (spent[requestType] or 0) + 1
			end
		end,

		waiting = function(_: Budget, queue: string): number
			return queues[queue] or 0
		end,
	}
	refill(self)
	return self
end

return Budget
