--!strict
--- Where a store keeps its profiles: the live data store, or memory (a scratch store, and Studio).
---
--- Studio cannot always reach live data. A published place with "Enable Studio Access to API Services"
--- off is refused on its first call: the store finds that out with one read on its first load (see
--- Store). A place file that was never published is refused earlier, when the data store itself is
--- asked for: `DataStoreService:GetDataStore` throws "You must publish this place to the web to access
--- DataStore." Either way the store runs in memory and says so once through `onError`. It never throws
--- for that: a game must start in Studio whatever the place file is.
---
--- Outside Studio nothing is caught here: a live server that cannot reach its data store must fail.
const MockServices = require("./MockServices")
const Services = require("./Services")

export type Mode = "live" | "memory" | "copy"

export type Chosen = {
	services: Services.Services,
	dataStore: Services.DataStore,
	--> Whether live data can be reached is settled: the first load makes no access check.
	checked: boolean,
	--> Studio could not reach live data: what `onError` is told on the first load.
	notice: string?,
}

const Studio = {}

--> Whether `problem`, thrown by a data store call, means Studio has no access to live data.
Studio.isNoAccess = MockServices.isNoAccess

--> What `onError` is told when Studio switches to memory because of `problem`.
function Studio.notice(problem: string): string
	return if string.find(problem, "must publish", 1, true) ~= nil
		then "This place is not published: profiles are kept in memory, and nothing is saved"
		else "Studio has no API access: profiles are kept in memory, and nothing is saved"
end

--> The services the store `name` runs on, and its data store. `mock` and `mode` are the store's options.
function Studio.choose(base: Services.Services, name: string, mock: (boolean | string)?, mode: Mode): Chosen
	const inMemory = base.isStudio and mode ~= "live"
	local services = base
	if mock then
		services = MockServices.wrap(base, if type(mock) == "string" then mock else "scratch")
	elseif inMemory then
		services = MockServices.wrap(base, `studio:{mode}`, mode == "copy")
	end
	-- Asking for the data store is the first thing that touches the engine's: an unpublished place
	-- throws here, for the live store and for the one "copy" would read from.
	const ok, found = pcall(function(): Services.DataStore
		return services.dataStores:GetDataStore(name)
	end)
	if ok then
		-- Studio on the live store still has its API access to find out, by a read on the first load.
		return { services = services, dataStore = found, checked = mock ~= nil or inMemory or not base.isStudio }
	end
	const problem = tostring(found)
	if not base.isStudio or not Studio.isNoAccess(problem) then
		error(found, 0)
	end
	const memory = MockServices.wrap(base, "studio")
	return {
		services = memory,
		dataStore = memory.dataStores:GetDataStore(name),
		checked = true,
		notice = Studio.notice(problem),
	}
end

return Studio
