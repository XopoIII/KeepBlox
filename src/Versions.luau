--!strict
--- Past versions of a key, for support: list them, read one, and restore one.
---
--- Roblox keeps the first write of every UTC hour as a backup for 30 days
--- (https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching). A
--- restore makes an old version's data current again, through the lock: it refuses while any server
--- holds the key, so it never races a live session. Kick the player first.
const Call = require("./Call")
const Record = require("./Record")
const Session = require("./Session")

export type Version = {
	version: string,
	--> Unix milliseconds.
	at: number,
	deleted: boolean,
}

export type Query = {
	--> Unix milliseconds; 0 or nil for no bound.
	from: number?,
	to: number?,
	newestFirst: boolean?,
	--> Stop after this many; default 100.
	limit: number?,
}

export type Restored = { ok: true } | { ok: false, reason: "inUse" | "notAProfile" | "failed" }

const DEFAULT_LIMIT = 100

const Versions = {}

--> The versions of `key` that match `query`.
function Versions.list(context: Session.Context, key: string, query: Query?): { Version }
	const options: Query = query or {}
	const limit = options.limit or DEFAULT_LIMIT
	const pages = context.dataStore:ListVersionsAsync(
		key,
		not options.newestFirst,
		options.from or 0,
		options.to or 0,
		math.min(limit, 1024)
	)
	const found: { Version } = {}
	while true do
		for _, info in pages:GetCurrentPage() do
			table.insert(found, { version = info.Version, at = info.CreatedTime, deleted = info.IsDeleted })
			if #found >= limit then
				return found
			end
		end
		if pages.IsFinished then
			return found
		end
		pages:AdvanceToNextPageAsync()
	end
end

--> The profile data `key` held at `version`, or nil when that version is not a profile.
function Versions.read(context: Session.Context, key: string, version: string): any
	const value = context.dataStore:GetVersionAsync(key, version)
	return if Record.classify(value) == "profile" then value.Data else nil
end

--> Makes `version`'s data current for `key`. Everything else in the record (its lock, messages and
--> receipts) stays as it is now.
function Versions.restore(context: Session.Context, key: string, version: string): Restored
	const old = context.dataStore:GetVersionAsync(key, version)
	if Record.classify(old) ~= "profile" then
		return { ok = false, reason = "notAProfile" }
	end
	const clock = context.services.clock
	local outcome: Restored = { ok = false, reason = "failed" } :: Restored
	const ok = Call.run(
		clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		key,
		function(value: any): any
			const kind = Record.classify(value)
			if kind == "foreign" then
				outcome = { ok = false, reason = "notAProfile" } :: Restored
				return nil
			end
			const record = if kind == "profile"
				then value
				else Record.fresh(old.Data, clock.time(), value and value.GlobalUpdates)
			if record.MetaData.ActiveSession ~= nil then
				outcome = { ok = false, reason = "inUse" } :: Restored
				return nil
			end
			record.Data = Record.copy(old.Data)
			record.MetaData.LastUpdate = clock.time()
			outcome = { ok = true } :: Restored
			return record
		end
	)
	if not ok then
		return { ok = false, reason = "failed" }
	end
	return outcome
end

return Versions
