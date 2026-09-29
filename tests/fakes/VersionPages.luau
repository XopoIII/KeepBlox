--!strict
--- `DataStoreVersionPages` and `DataStoreKeyInfo` over the fake backend's versions.
---
--- Sources: https://create.roblox.com/docs/reference/engine/classes/DataStore (ListVersionsAsync:
--- minDate and maxDate in Unix milliseconds, 0 for no bound; pageSize 0 means 1024), DataStoreKeyInfo
--- and DataStoreObjectVersionInfo. Advancing past the last page throws "No pages to advance to.".
const Backend = require("./Backend")
const Services = require("@keepblox/Services")

const VersionPages = {}

const DEFAULT_PAGE_SIZE = 1024

--> The KeyInfo a call returns for `version` of a key first written at `createdMs`.
function VersionPages.keyInfo(version: Backend.Version, createdMs: number): Services.KeyInfo
	const userIds = table.clone(version.userIds)
	const metadata = table.clone(version.metadata)
	return {
		CreatedTime = createdMs,
		UpdatedTime = version.createdMs,
		Version = version.id,
		GetUserIds = function(_: Services.KeyInfo): { number }
			return table.clone(userIds)
		end,
		GetMetadata = function(_: Services.KeyInfo): { [string]: any }
			return table.clone(metadata)
		end,
	}
end

export type Query = {
	ascending: boolean,
	minDate: number,
	maxDate: number,
	pageSize: number,
}

--> Pages over `versions` (oldest first). `advance` is called before each later page is served, so the
--> caller can charge it as a request (it yields and may throw).
function VersionPages.new(versions: { Backend.Version }, query: Query, advance: () -> ()): Services.VersionPages
	const matching: { Services.VersionInfo } = {}
	for _, version in versions do
		const at = version.createdMs
		if (query.minDate == 0 or at >= query.minDate) and (query.maxDate == 0 or at <= query.maxDate) then
			table.insert(matching, { Version = version.id, CreatedTime = at, IsDeleted = version.deleted })
		end
	end
	if not query.ascending then
		const reversed: { Services.VersionInfo } = {}
		for index = #matching, 1, -1 do
			table.insert(reversed, matching[index])
		end
		table.clear(matching)
		table.move(reversed, 1, #reversed, 1, matching)
	end

	const size = if query.pageSize == 0 then DEFAULT_PAGE_SIZE else query.pageSize
	local first = 1

	const pages: Services.VersionPages = {
		IsFinished = #matching <= size,
		GetCurrentPage = function(_: Services.VersionPages): { Services.VersionInfo }
			return table.move(matching, first, math.min(first + size - 1, #matching), 1, {})
		end,
		AdvanceToNextPageAsync = function(self: Services.VersionPages)
			if self.IsFinished then
				error("No pages to advance to.", 0)
			end
			advance()
			first += size
			self.IsFinished = first + size > #matching
		end,
	}
	return pages
end

return VersionPages
