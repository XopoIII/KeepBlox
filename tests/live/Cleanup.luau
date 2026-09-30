--!strict
--- Removes everything live checks left, fast and completely:
--- - every key of every data store named `KB_LiveCheck_*`, deleted keys skipped;
--- - the ordered data stores of those runs (`<run>_ord`, `<run>_ord2`), which cannot be listed;
--- - the MemoryStore heartbeat entries of the check's virtual servers (`KB_servers`, jobId `livecheck-*`).
--- Then it lists again and reports what is left, which must be nothing.
---
--- Storage counts only the latest version of each key that is not deleted: once a key is removed it
--- costs nothing, though Roblox keeps its old versions for 30 days (nothing can remove those sooner).
---
--- Speed: `workers` removes run at once, paced to `perMinute` and to this server's remove budget, and a
--- throttled remove is tried again. In a live game keep `perMinute` low (20): the experience's limit
--- (300 + 40 x players a minute) is shared with the players' saves. In the test experience go fast.
const DataStoreService = game:GetService("DataStoreService")
const MemoryStoreService = game:GetService("MemoryStoreService")

export type Options = { perMinute: number?, workers: number? }

const Cleanup = {}

const PREFIX = "KB_LiveCheck_"
const TRIES = 6

-- Runs `remove` on every item `next()` yields, `workers` at a time, at most `perMinute`, within budget.
const function drain(next: () -> any?, remove: (any) -> (), perMinute: number, workers: number): number
	local done, active, sentAt = 0, 0, 0
	const gap = 60 / perMinute
	local finished = false
	for _ = 1, workers do
		active += 1
		task.spawn(function()
			while true do
				const item = next()
				if item == nil then
					break
				end
				-- One remove per `gap` seconds across all workers, and only while the server has budget.
				while
					os.clock() - sentAt < gap
					or DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRemove) < 1
				do
					task.wait(0.05)
				end
				sentAt = os.clock()
				for try = 1, TRIES do
					if pcall(remove, item) then
						done += 1
						break
					end
					task.wait(try)
				end
			end
			active -= 1
			if active == 0 then
				finished = true
			end
		end)
	end
	while not finished do
		task.wait(0.1)
	end
	return done
end

-- The names of every `KB_LiveCheck_*` data store.
const function storeNames(): { string }
	const names = {}
	const pages = DataStoreService:ListDataStoresAsync(PREFIX)
	while true do
		for _, info in pages:GetCurrentPage() :: any do
			table.insert(names, info.DataStoreName)
		end
		if pages.IsFinished then
			return names
		end
		pages:AdvanceToNextPageAsync()
	end
end

-- The keys of `store` that are not deleted.
const function liveKeys(store: DataStore): { string }
	const keys = {}
	const pages = store:ListKeysAsync("", 100, "", true)
	while true do
		for _, key in pages:GetCurrentPage() :: any do
			table.insert(keys, key.KeyName)
		end
		if pages.IsFinished then
			return keys
		end
		pages:AdvanceToNextPageAsync()
	end
end

--> Removes everything; `log` hears the progress. Returns how many keys are left (0 when complete).
function Cleanup.run(log: (string) -> (), options: Options?): number
	const perMinute = options and options.perMinute or 20
	const workers = options and options.workers or 8
	const began = os.clock()
	const names = storeNames()
	-- Every key of every store, in one queue.
	const queue: { { store: DataStore, key: string } } = {}
	const runs: { [string]: boolean } = {}
	for _, name in names do
		const store = DataStoreService:GetDataStore(name)
		for _, key in liveKeys(store) do
			table.insert(queue, { store = store, key = key })
		end
		const run = string.match(name, "^KB_LiveCheck_(%x+)")
		if run then
			runs[run] = true
		end
	end
	log(`cleanup: {#names} data stores, {#queue} keys`)
	local index = 0
	const removed = drain(function(): any?
		index += 1
		return queue[index]
	end, function(item: any)
		item.store:RemoveAsync(item.key)
	end, perMinute, workers)
	log(`cleanup: {removed} keys removed in {string.format("%.0f", os.clock() - began)} s`)

	-- Ordered stores cannot be listed: the names the conformance checks use, for every run found.
	local ordered = 0
	for run in runs do
		for _, suffix in { "_ord", "_ord2" } do
			const store = DataStoreService:GetOrderedDataStore(`{PREFIX}{run}{suffix}`)
			const ok, page = pcall(function(): any
				return store:GetSortedAsync(true, 100):GetCurrentPage()
			end)
			for _, entry in if ok then page else {} do
				if pcall(store.RemoveAsync, store, entry.key) then
					ordered += 1
				end
			end
		end
	end
	log(`cleanup: {ordered} ordered keys removed`)

	-- The heartbeat entries of the check's virtual servers.
	const servers = MemoryStoreService:GetSortedMap("KB_servers")
	local beats = 0
	while true do
		const ok, items = pcall(function(): any
			return servers:GetRangeAsync(
				Enum.SortDirection.Ascending,
				200,
				{ key = "livecheck-" },
				{ key = "livecheck." }
			)
		end)
		if not ok or #items == 0 then
			break
		end
		for _, item in items do
			if pcall(servers.RemoveAsync, servers, item.key) then
				beats += 1
			end
		end
	end
	log(`cleanup: {beats} MemoryStore heartbeat entries removed`)

	-- What is left must be nothing.
	local left = 0
	for _, name in storeNames() do
		left += #liveKeys(DataStoreService:GetDataStore(name))
	end
	log(`cleanup: {left} keys left in {PREFIX}* data stores`)
	return left
end

return Cleanup
