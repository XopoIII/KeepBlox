--!strict
--- A schedule's index (see Schedule): an ordered data store holding, for each key, a second at or
--- before which its job is due. A sweep reads the keys whose second has come, in order.
---
--- The index is never written blind. Its one rule: **while a key holds a job, the index holds a second
--- no later than the job's due time**, so a job is never found late. Too early is harmless: a sweep that
--- finds a job not due yet moves the index to it. Each write keeps to the rule through any interleaving
--- with other servers:
---
--- - `lower` moves a key's second earlier, never later: it runs after the record's write, and of two
---   servers writing a key at once the index keeps the earlier of their seconds.
--- - `settle` moves it anywhere (later, or to `PARKED` once the key holds no job), but only from the
---   second it was seen at, and then reads the record again and `lower`s to the job found there. A game's
---   change that landed meanwhile has either been read there, or `lower`s the index itself after it.
---
--- A key's index entry is parked rather than removed: a removal could not be made conditional, and a
--- parked entry is never due.
const Call = require("./Call")
const JobRecord = require("./JobRecord")
const Services = require("./Services")

const JobIndex = {}

--> Where a key without a job is parked: past every due time a job may have.
JobIndex.PARKED = JobRecord.LATEST

--> What the index's writes need: the stores, the clock and how long one call may take.
export type Stores = {
	dataStore: Services.DataStore,
	index: Services.OrderedDataStore,
	clock: Services.Clock,
	timeout: number,
}

--> Moves `key`'s second to `due` when it holds none or a later one. Whether the call answered.
function JobIndex.lower(stores: Stores, key: string, due: number): boolean
	const ok = Call.run(stores.clock, stores.timeout, function()
		stores.index:UpdateAsync(key, function(current: number?): number?
			if current ~= nil and current <= due then
				return nil
			end
			return due
		end)
	end)
	return ok
end

--> Moves `key`'s second from `seen` to `target` (`PARKED` for none), only if it is still `seen`; then
--> reads the record again and lowers the second to the job it holds, if any. Whether every call
--> answered: when one did not, the index may still be early, never late.
function JobIndex.settle(stores: Stores, key: string, seen: number, target: number): boolean
	const moved = Call.run(stores.clock, stores.timeout, function()
		stores.index:UpdateAsync(key, function(current: number?): number?
			return if current == seen then target else nil
		end)
	end)
	if not moved then
		return false
	end
	const read, value = Call.run(stores.clock, stores.timeout, function(): any
		return (stores.dataStore:GetAsync(key, false))
	end)
	if not read then
		-- The second may now be later than a job a change stored meanwhile: put it back where it was.
		JobIndex.lower(stores, key, seen)
		return false
	end
	if JobRecord.classify(value) == "job" then
		const due = JobRecord.second(value.due)
		if due and due < target then
			return JobIndex.lower(stores, key, due)
		end
	end
	return true
end

return JobIndex
