--!strict
--- Past versions of a key, for support: list them, read one, and restore one.
---
--- Roblox keeps the first write of every UTC hour as a backup for 30 days
--- (https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching). A
--- restore makes an old version's data current again, through the lock: it refuses while any server
--- holds the key, so it never races a live session. Kick the player first.
const Call = require("./Call")
const Codec = require("./Codec")
const Migrate = require("./Migrate")
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

--> `purchasesSince`: the purchase ids granted after `version`, oldest first. The restored data is from
--> before them, and they stay granted (a restore never replays a purchase), so the game must make them
--> good. Only ids still in the kept history (see Receipts) are known.
--> `noVersion`: the key has no such version now. A version is overwritten by later writes in its UTC
--> hour, and an id that is not well formed names none (both seen live).
export type Restored =
	{ ok: true, purchasesSince: { string } }
	| { ok: false, reason: "inUse" | "notAProfile" | "noVersion" | "failed" }

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

-- The value `key` held at `version`: "found" and the value, "noVersion" (none, or an id that is not
-- one: the engine's error 25), or "failed" and the error.
const function fetch(context: Session.Context, key: string, version: string): (string, any)
	const ok, value = Call.run(
		context.services.clock,
		context.config.callTimeout,
		context.dataStore.GetVersionAsync,
		context.dataStore,
		key,
		version
	)
	if not ok then
		return if string.find(tostring(value), "Error code: 25", 1, true) then "noVersion" else "failed", value
	end
	return if value == nil then "noVersion" else "found", value
end

--> The profile data `key` held at `version`, or nil when there is no such version or it is not a
--> profile. A failed call throws.
function Versions.read(context: Session.Context, key: string, version: string): any
	const status, value = fetch(context, key, version)
	if status == "failed" then
		error(`KeepBlox: could not read version {version} of {key}: {value}`, 2)
	end
	return if status == "found" and Record.classify(value) == "profile"
		then Codec.unpack(context.services.codec, value.Data)
		else nil
end

--> Makes `version`'s data current for `key`, with the schema version it was stored at, so the
--> migrations since then run on it at the next load. Everything else in the record (its lock, messages
--> and receipts) stays as it is now. The record notes the restore (`restored = { from, at }`), and the
--> result names the purchases it rolled back (a rollback is an audited new version, as in Rebound,
--> IEEE S&P 2026).
function Versions.restore(context: Session.Context, key: string, version: string): Restored
	const status, old = fetch(context, key, version)
	if status ~= "found" then
		return { ok = false, reason = status } :: Restored
	elseif Record.classify(old) ~= "profile" then
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
			const ours = Record.ours(record.MetaData)
			const storedAt = Migrate.stored(old)
			ours.schemaVersion = if storedAt > 0 then storedAt else nil
			const before = Record.receipts(old.MetaData)
			const since = {}
			for _, id in Record.receipts(record.MetaData) do
				if not table.find(before, id) then
					table.insert(since, id)
				end
			end
			ours.restored = { from = version, at = clock.time() }
			-- A dead owner's last beat was play on the data this restore replaces (see Owed).
			ours.owed = nil
			record.MetaData.LastUpdate = clock.time()
			outcome = { ok = true, purchasesSince = since } :: Restored
			return record
		end
	)
	if not ok then
		return { ok = false, reason = "failed" }
	end
	return outcome
end

return Versions
