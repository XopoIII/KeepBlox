--!strict
--- One server's `OrderedDataStore` handle over a shared set of sorted stores: the seam's
--- `Services.OrderedDataStore`.
---
--- Sources: https://create.roblox.com/docs/reference/engine/classes/OrderedDataStore and
--- https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits:
--- - values are integers; `GetSortedAsync(ascending, pageSize, minValue, maxValue)` returns pages of
---   `{key, value}`, pageSize at most 100;
--- - per-server budgets: OrderedRead 60 + players x 40, OrderedWrite 30 + players x 5, OrderedList
---   5 + players x 2, OrderedRemove 30 + players x 5 (Budget). UpdateAsync is a read and a write.
--- Every call yields and can fault, as the standard store's calls do. Ties: the docs are silent; live
--- (2026-09-30) they come in a fixed order that is neither by key nor by insertion, ascending the exact
--- reverse of descending. Here that order is a hash of the key, so nothing can come to rely on
--- alphabetical ties.
const Budget = require("./Budget")
const Errors = require("./Errors")
const Faults = require("./Faults")
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

export type Shared = { [string]: { [string]: number } }

-- FNV-1a of the key: where a key falls among equal values.
const function tieRank(key: string): number
	local hash = 2166136261
	for index = 1, #key do
		hash = bit32.bxor(hash, string.byte(key, index))
		hash = (hash * 16777619) % 4294967296
	end
	return hash
end

export type Context = {
	scheduler: Scheduler.Scheduler,
	faults: Faults.Faults,
	budget: Budget.Budget,
	server: string,
	shared: Shared,
}

const MAX_PAGE = 100

const Ordered = {}

const function checkValue(value: any)
	if type(value) ~= "number" or value ~= math.floor(value) or value ~= value then
		error(Errors.cantStore("a value that is not an integer in an ordered data store"), 0)
	end
end

function Ordered.new(context: Context, store: string): Services.OrderedDataStore
	const scheduler, faults, budget = context.scheduler, context.faults, context.budget
	context.shared[store] = context.shared[store] or {}
	const values = context.shared[store]

	const function call(op: string, key: string?, types: { Services.RequestType }, queue: string)
		budget:acquire(types :: any, queue, Errors.queueFull(305, op))
		const rule = faults:match(op, key, context.server, false)
		if rule then
			if rule.hang then
				scheduler:wait(math.huge)
			end
			error(rule.error, 0)
		end
		scheduler:wait(faults:sample())
	end

	const handle = {}
	function handle.GetAsync(_: Services.OrderedDataStore, key: string): number?
		call("OrderedGetAsync", key, { "OrderedRead" }, "OrderedRead")
		return values[key]
	end
	function handle.SetAsync(_: Services.OrderedDataStore, key: string, value: number)
		checkValue(value)
		call("OrderedSetAsync", key, { "OrderedWrite" }, "OrderedWrite")
		values[key] = value
	end
	function handle.UpdateAsync(
		_: Services.OrderedDataStore,
		key: string,
		transform: (current: number?) -> number?
	): number?
		call("OrderedUpdateAsync", key, { "OrderedRead", "OrderedWrite" }, "OrderedWrite")
		const result = transform(values[key])
		if result == nil then
			return nil
		end
		checkValue(result)
		values[key] = result
		return result
	end
	function handle.RemoveAsync(_: Services.OrderedDataStore, key: string): number?
		call("OrderedRemoveAsync", key, { "OrderedRemove" }, "OrderedRemove")
		const old = values[key]
		values[key] = nil
		return old
	end
	function handle.GetSortedAsync(
		_: Services.OrderedDataStore,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?
	): Services.SortedPages
		assert(pageSize >= 1 and pageSize <= MAX_PAGE, `pageSize must be 1-{MAX_PAGE}`)
		call("GetSortedAsync", nil, { "OrderedList" }, "OrderedList")
		const entries: { Services.SortedEntry } = {}
		for key, value in values do
			if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
				table.insert(entries, { key = key, value = value })
			end
		end
		table.sort(entries, function(a: Services.SortedEntry, b: Services.SortedEntry): boolean
			if a.value ~= b.value then
				return if ascending then a.value < b.value else a.value > b.value
			end
			const ha, hb = tieRank(a.key), tieRank(b.key)
			if ha ~= hb then
				return if ascending then ha > hb else ha < hb
			end
			return if ascending then a.key > b.key else a.key < b.key
		end)
		local page = 1
		const pages = {}
		const function current(): { Services.SortedEntry }
			const out = {}
			for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #entries) do
				table.insert(out, table.clone(entries[index]))
			end
			return out
		end
		pages.IsFinished = #entries <= pageSize
		function pages.GetCurrentPage(_: Services.SortedPages): { Services.SortedEntry }
			return current()
		end
		function pages.AdvanceToNextPageAsync(this: Services.SortedPages)
			assert(not this.IsFinished, "No pages to advance to.")
			call("GetSortedAsync", nil, { "OrderedList" }, "OrderedList")
			page += 1
			this.IsFinished = page * pageSize >= #entries
		end
		return pages :: Services.SortedPages
	end
	return handle :: Services.OrderedDataStore
end

return Ordered
