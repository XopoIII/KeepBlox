--!strict
--- Removes what live checks left: every key of every data store named `KB_LiveCheck_*`, slowly.
---
--- It touches nothing else, so it may run in any experience, the live game included: at `perMinute`
--- removes (20 by default) it stays far below the experience's limit (300 + 40 per player a minute).
--- Ordered data stores cannot be listed; the few keys the conformance checks write to them stay.
const DataStoreService = game:GetService("DataStoreService")

const Cleanup = {}

const PREFIX = "KB_LiveCheck_"

--> Removes every key of the live check's data stores; `log` hears the progress. Returns the count.
function Cleanup.run(log: (string) -> (), perMinute: number?): number
	const pause = 60 / (perMinute or 20)
	local removed = 0
	const stores = DataStoreService:ListDataStoresAsync(PREFIX)
	while true do
		for _, info in stores:GetCurrentPage() :: any do
			const name = info.DataStoreName
			const store = DataStoreService:GetDataStore(name)
			const keys = store:ListKeysAsync()
			while true do
				for _, key in keys:GetCurrentPage() :: any do
					const ok, problem = pcall(store.RemoveAsync, store, key.KeyName)
					if ok then
						removed += 1
					else
						log(`cleanup: {name}/{key.KeyName}: {problem}`)
					end
					task.wait(pause)
				end
				if keys.IsFinished then
					break
				end
				keys:AdvanceToNextPageAsync()
			end
			log(`cleanup: {name} emptied ({removed} removed so far)`)
		end
		if stores.IsFinished then
			break
		end
		stores:AdvanceToNextPageAsync()
	end
	return removed
end

return Cleanup
