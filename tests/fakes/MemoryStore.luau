--!strict
--- MemoryStoreService, shared by every server of a world: sorted maps, hash maps and queues.
---
--- Sources: https://create.roblox.com/docs/cloud-services/memory-stores and the class pages
--- (MemoryStoreSortedMap, MemoryStoreHashMap, MemoryStoreQueue):
--- - every item expires after its expiration (0 to 3,888,000 s); an expired item reads as missing;
--- - a value is at most 32 KB; the experience holds at most 64 KB + 1.2 KB per user;
--- - the experience makes at most 1000 + 120 per user request units a minute; a hash map's UpdateAsync
---   costs two;
--- - UpdateAsync's transform may run again when the item changed meanwhile; returning nil cancels;
--- - a queue item read is invisible for the queue's invisibility timeout (default 30 s) until removed
---   with the id ReadAsync returned; ReadAsync waits up to `waitTimeout` for items.
--- Every call yields (latency) and can fault, as the data store's calls do.
const Encoding = require("./Encoding")
const Faults = require("./Faults")
const Scheduler = require("./Scheduler")

type Item = { value: any, expiresAt: number, sortKey: any? }

export type Shared = {
	maps: { [string]: { [string]: Item } },
	queues: {
		[string]: { { id: number, value: any, expiresAt: number, priority: number, hiddenUntil: number, readId: string? } },
	},
	--> Request units spent this minute window, and when the window began.
	units: number,
	--> Request units each server spent in all (the benchmarks read it).
	spent: { [string]: number },
	windowStart: number,
	--> Players across the experience; the quotas scale with it.
	players: () -> number,
	nextId: number,
}

const MAX_EXPIRATION = 3_888_000
const MAX_VALUE = 32 * 1024

const MemoryStore = {}

function MemoryStore.shared(players: () -> number): Shared
	return { maps = {}, queues = {}, units = 0, spent = {}, windowStart = 0, players = players, nextId = 0 }
end

function MemoryStore.service(scheduler: Scheduler.Scheduler, faults: Faults.Faults, shared: Shared, server: string): any
	const function now(): number
		return scheduler.now
	end

	const function charge(op: string, key: string?, units: number)
		if now() - shared.windowStart >= 60 then
			shared.windowStart, shared.units = now(), 0
		end
		if shared.units + units > 1000 + 120 * shared.players() then
			error("TotalRequestsOverLimit: the experience is over its memory store request units", 0)
		end
		shared.units += units
		shared.spent[server] = (shared.spent[server] or 0) + units
		const rule = faults:match(op, key, server, false)
		scheduler:wait(faults:sample())
		if rule then
			if rule.hang then
				scheduler:wait(math.huge)
			end
			error(rule.error, 0)
		end
	end

	const function live(item: Item?): Item?
		return if item and item.expiresAt > now() then item else nil
	end

	const function used(): number
		local total = 0
		for _, map in shared.maps do
			for key, item in map do
				if live(item) then
					total += #key + Encoding.size(item.value)
				end
			end
		end
		for _, queue in shared.queues do
			for _, entry in queue do
				if entry.expiresAt > now() then
					total += Encoding.size(entry.value)
				end
			end
		end
		return total
	end

	const function checkPut(value: any, expiration: number, old: number)
		assert(
			type(expiration) == "number" and expiration >= 0 and expiration <= MAX_EXPIRATION,
			"expiration must be 0-3888000"
		)
		const size = Encoding.size(value)
		if size > MAX_VALUE then
			error("ItemValueSizeTooLarge: a memory store value is at most 32 KB", 0)
		end
		if used() - old + size > 64 * 1024 + 1229 * shared.players() then
			error("ExceededMemoryQuota: the experience is over its memory store quota", 0)
		end
	end

	const function map(name: string, kind: string): any
		const id = `{kind}:{name}`
		shared.maps[id] = shared.maps[id] or {}
		const items = shared.maps[id]
		const updateUnits = if kind == "hash" then 2 else 1
		const handle = {}
		function handle.GetAsync(_: any, key: string): (any, any)
			charge("MemoryStoreGetAsync", key, 1)
			const item = live(items[key])
			return if item then Encoding.copy(item.value) else nil, if item then item.sortKey else nil
		end
		function handle.SetAsync(_: any, key: string, value: any, expiration: number, sortKey: any?): boolean
			charge("MemoryStoreSetAsync", key, 1)
			const old = live(items[key])
			checkPut(value, expiration, if old then #key + Encoding.size(old.value) else 0)
			items[key] = { value = Encoding.copy(value), expiresAt = now() + expiration, sortKey = sortKey }
			return true
		end
		function handle.UpdateAsync(_: any, key: string, transform: (any, any) -> (any, any), expiration: number): any
			charge("MemoryStoreUpdateAsync", key, updateUnits)
			const old = live(items[key])
			const value, sortKey =
				transform(if old then Encoding.copy(old.value) else nil, if old then old.sortKey else nil)
			if value == nil then
				return nil
			end
			checkPut(value, expiration, if old then #key + Encoding.size(old.value) else 0)
			items[key] = { value = Encoding.copy(value), expiresAt = now() + expiration, sortKey = sortKey }
			return Encoding.copy(value)
		end
		function handle.RemoveAsync(_: any, key: string)
			charge("MemoryStoreRemoveAsync", key, 1)
			items[key] = nil
		end
		return handle
	end

	const function queue(name: string, invisibility: number?): any
		shared.queues[name] = shared.queues[name] or {}
		const entries = shared.queues[name]
		const hide = invisibility or 30
		const handle = {}
		function handle.AddAsync(_: any, value: any, expiration: number, priority: number?)
			charge("MemoryStoreAddAsync", nil, 1)
			checkPut(value, expiration, 0)
			shared.nextId += 1
			table.insert(entries, {
				id = shared.nextId,
				value = Encoding.copy(value),
				expiresAt = now() + expiration,
				priority = priority or 0,
				hiddenUntil = 0,
				readId = nil,
			})
			table.sort(entries, function(a: any, b: any): boolean
				return if a.priority ~= b.priority then a.priority > b.priority else a.id < b.id
			end)
		end
		function handle.ReadAsync(
			_: any,
			count: number,
			allOrNothing: boolean?,
			waitTimeout: number?
		): ({ any }, string?)
			charge("MemoryStoreReadAsync", nil, 1)
			const deadline = now() + math.max(waitTimeout or 0, 0)
			while true do
				const found = {}
				for _, entry in entries do
					if entry.expiresAt > now() and entry.hiddenUntil <= now() and #found < count then
						table.insert(found, entry)
					end
				end
				if #found > 0 and (not allOrNothing or #found == count) then
					shared.nextId += 1
					const readId = `read-{shared.nextId}`
					const values = {}
					for _, entry in found do
						entry.hiddenUntil, entry.readId = now() + hide, readId
						table.insert(values, Encoding.copy(entry.value))
					end
					return values, readId
				end
				if now() >= deadline then
					return {}, nil
				end
				scheduler:wait(math.min(1, deadline - now()))
			end
		end
		function handle.RemoveAsync(_: any, readId: string)
			charge("MemoryStoreRemoveAsync", nil, 1)
			for index = #entries, 1, -1 do
				if entries[index].readId == readId then
					table.remove(entries, index)
				end
			end
		end
		return handle
	end

	return {
		GetSortedMap = function(_: any, name: string): any
			return map(name, "sorted")
		end,
		GetHashMap = function(_: any, name: string): any
			return map(name, "hash")
		end,
		GetQueue = function(_: any, name: string, invisibilityTimeout: number?): any
			return queue(name, invisibilityTimeout)
		end,
	}
end

return MemoryStore
