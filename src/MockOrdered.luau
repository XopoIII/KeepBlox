--!strict
--- An in-memory `OrderedDataStore`, for mock and Studio stores (see MockServices): integers by key,
--- read back in sorted pages. Nothing here reaches a live store.
const Services = require("./Services")

const MockOrdered = {}

function MockOrdered.new(values: { [string]: number }): Services.OrderedDataStore
	const function check(value: any)
		assert(type(value) == "number" and value == math.floor(value), "an ordered data store holds integers")
	end

	const handle = {}
	function handle.GetAsync(_: Services.OrderedDataStore, key: string): number?
		return values[key]
	end
	function handle.SetAsync(_: Services.OrderedDataStore, key: string, value: number)
		check(value)
		values[key] = value
	end
	function handle.UpdateAsync(
		_: Services.OrderedDataStore,
		key: string,
		transform: (current: number?) -> number?
	): number?
		const result = transform(values[key])
		if result ~= nil then
			check(result)
			values[key] = result
		end
		return result
	end
	function handle.RemoveAsync(_: Services.OrderedDataStore, key: string): number?
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
			return a.key < b.key
		end)
		local page = 1
		const pages = { IsFinished = #entries <= pageSize }
		function pages.GetCurrentPage(_: Services.SortedPages): { Services.SortedEntry }
			const out = {}
			for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #entries) do
				table.insert(out, table.clone(entries[index]))
			end
			return out
		end
		function pages.AdvanceToNextPageAsync(this: Services.SortedPages)
			assert(not this.IsFinished, "No pages to advance to.")
			page += 1
			this.IsFinished = page * pageSize >= #entries
		end
		return pages :: any
	end
	return handle :: Services.OrderedDataStore
end

return MockOrdered
