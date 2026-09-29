--!strict
--- One server's data store request budget, per request type.
---
--- Source: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
--- - Per-server limits, per minute: StandardRead and StandardWrite 60 + players x 40, StandardList
---   5 + players x 2, StandardRemove 60 + players x 40. UpdateAsync "consumes from both the read and
---   write request budgets".
--- - Over budget, a request waits in its queue; "Each queue has a limit of 30 requests. When the limit of
---   a queue is reached, requests fail with an error code in the 301-306 range".
---
--- Assumed until the live check: the budget refills continuously, holds at most one minute's worth, and
--- starts full (the docs mention a startup burst without a size).
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

type RequestType = Services.RequestType

export type Budget = {
	--> Players on this server; the rates scale with it.
	players: number,
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
}

const Budget = {}

function Budget.new(scheduler: Scheduler.Scheduler, players: number?): Budget
	const tokens: { [RequestType]: number } = {}
	const queues: { [string]: number } = {}
	local refilledAt = scheduler.now

	const function perMinute(self: Budget, requestType: RequestType): number
		const rate = RATES[requestType]
		return rate.base + rate.perPlayer * self.players
	end

	const function refill(self: Budget)
		const elapsed = scheduler.now - refilledAt
		refilledAt = scheduler.now
		for requestType in RATES do
			const cap = perMinute(self, requestType)
			tokens[requestType] = math.min(cap, (tokens[requestType] or cap) + elapsed * cap / 60)
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
					scheduler:wait(delay)
					refill(budget)
				end
				queues[queue] -= 1
			end
			for _, requestType in types do
				tokens[requestType] -= 1
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
