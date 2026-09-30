--!strict
--- The data store service itself: what Roblox keeps in the cloud, shared by every virtual server.
---
--- Every operation here is atomic (it never yields); the per-server handle (`DataStore.luau`) adds the
--- latency, budgets, cache and faults around it. Rules copied from the docs:
---
--- - Versions (https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching):
---   "SetAsync(), UpdateAsync(), and IncrementAsync() create versioned backups of your data using the
---   first write to each key in each UTC hour. Successive writes to a key in the same UTC hour
---   permanently overwrite the previous data." A remove writes a deleted "tombstone" version, always as
---   a version of its own; the next write in the same hour replaces the tombstone (live check).
--- - Per-key write throughput (error-codes-and-limits, "Throughput limits"): 4 MB per minute, measured
---   over the last 60 seconds including the current request, each request rounded up to a kilobyte.
--- - Metadata (error-codes-and-limits, "Metadata limits"): the whole metadata table at most 300
---   characters as JSON.
const Encoding = require("./Encoding")
const Errors = require("./Errors")

export type Version = {
	id: string,
	createdMs: number,
	value: any,
	userIds: { number },
	metadata: { [string]: any },
	deleted: boolean,
}

type Entry = {
	createdMs: number,
	versions: { Version },
	writes: { { atMs: number, kilobytes: number } },
}

export type WriteEvent = {
	store: string,
	key: string,
	--> The latest version before this write, or nil for the first write of the key.
	previous: Version?,
	version: Version,
	--> The server that made the call, when the caller named one.
	writer: string?,
}

export type Backend = {
	--> The latest version of a key, deleted or not; nil if the key was never written.
	latest: (self: Backend, store: string, key: string) -> Version?,
	--> When the key was first written, in Unix milliseconds.
	createdMs: (self: Backend, store: string, key: string) -> number?,
	--> Writes a new latest version (or overwrites the latest, within the same UTC hour).
	write: (
		self: Backend,
		store: string,
		key: string,
		value: any,
		userIds: { number },
		metadata: { [string]: any },
		nowMs: number,
		writer: string?
	) -> Version,
	--> Writes a tombstone. Returns the version it replaced as latest, or nil.
	remove: (self: Backend, store: string, key: string, nowMs: number, writer: string?) -> Version?,
	--> Calls `listener` after every committed write and remove, in commit order.
	observe: (self: Backend, listener: (WriteEvent) -> ()) -> (),
	--> Every retained version, oldest first.
	versions: (self: Backend, store: string, key: string) -> { Version },
	--> One version by id, or nil.
	version: (self: Backend, store: string, key: string, id: string) -> Version?,
}

const VALUE_LIMIT = 4_194_304
const METADATA_LIMIT = 300
const WRITE_THROUGHPUT_KB = 4 * 1024
const HOUR_MS = 3_600_000
const MINUTE_MS = 60_000

const Backend = {}

function Backend.new(): Backend
	const stores: { [string]: { [string]: Entry } } = {}
	local sequence = 0

	const function entry(store: string, key: string): Entry?
		const keys = stores[store]
		return if keys then keys[key] else nil
	end

	const function ensure(store: string, key: string, nowMs: number): Entry
		local keys = stores[store]
		if not keys then
			keys = {}
			stores[store] = keys
		end
		local found = keys[key]
		if not found then
			found = { createdMs = nowMs, versions = {}, writes = {} }
			keys[key] = found
		end
		return found
	end

	-- Charges the write against the key's 60-second window, or throws KeyThrottled.
	const function charge(found: Entry, bytes: number, nowMs: number)
		const kilobytes = math.max(1, math.ceil(bytes / 1024))
		const kept = {}
		local used = kilobytes
		for _, write in found.writes do
			if nowMs - write.atMs < MINUTE_MS then
				table.insert(kept, write)
				used += write.kilobytes
			end
		end
		if used > WRITE_THROUGHPUT_KB then
			found.writes = kept
			error(Errors.keyThrottled(), 0)
		end
		table.insert(kept, { atMs = nowMs, kilobytes = kilobytes })
		found.writes = kept
	end

	const listeners: { (WriteEvent) -> () } = {}

	const function append(found: Entry, version: Version, store: string, key: string, writer: string?)
		const versions = found.versions
		const last = versions[#versions]
		-- Only the first write in a UTC hour is kept as a backup; later ones in that hour replace it. A
		-- tombstone never replaces: it is always its own version, which the next write in its hour
		-- replaces (live check, 2026-09-30).
		if
			last
			and not version.deleted
			and math.floor(last.createdMs / HOUR_MS) == math.floor(version.createdMs / HOUR_MS)
		then
			versions[#versions] = version
		else
			table.insert(versions, version)
		end
		const event: WriteEvent = { store = store, key = key, previous = last, version = version, writer = writer }
		for _, listener in listeners do
			listener(event)
		end
	end

	const function newId(nowMs: number): string
		sequence += 1
		return string.format("%016X.%010d.%016X.01", nowMs, sequence, nowMs)
	end

	const self: Backend = {
		latest = function(_: Backend, store: string, key: string): Version?
			const found = entry(store, key)
			return if found then found.versions[#found.versions] else nil
		end,

		createdMs = function(_: Backend, store: string, key: string): number?
			const found = entry(store, key)
			return if found then found.createdMs else nil
		end,

		write = function(
			_: Backend,
			store: string,
			key: string,
			value: any,
			userIds: { number },
			metadata: { [string]: any },
			nowMs: number,
			writer: string?
		): Version
			const size = Encoding.size(value)
			if size > VALUE_LIMIT then
				error(Errors.valueTooLarge(VALUE_LIMIT), 0)
			end
			for _, userId in userIds do
				if type(userId) ~= "number" or userId ~= math.floor(userId) then
					error(Errors.attributeFormat("userId"), 0)
				end
			end
			if Encoding.size(metadata) > METADATA_LIMIT then
				error(Errors.metadataTooLarge(METADATA_LIMIT), 0)
			end
			const found = ensure(store, key, nowMs)
			charge(found, size, nowMs)
			const version: Version = {
				id = newId(nowMs),
				createdMs = nowMs,
				value = Encoding.stored(value),
				userIds = table.clone(userIds),
				metadata = Encoding.copy(metadata),
				deleted = false,
			}
			append(found, version, store, key, writer)
			return version
		end,

		remove = function(_: Backend, store: string, key: string, nowMs: number, writer: string?): Version?
			const found = entry(store, key)
			if not found then
				return nil
			end
			const previous = found.versions[#found.versions]
			append(found, {
				id = newId(nowMs),
				createdMs = nowMs,
				value = nil,
				userIds = {},
				metadata = {},
				deleted = true,
			}, store, key, writer)
			return if previous and not previous.deleted then previous else nil
		end,

		observe = function(_: Backend, listener: (WriteEvent) -> ())
			table.insert(listeners, listener)
		end,

		versions = function(_: Backend, store: string, key: string): { Version }
			const found = entry(store, key)
			return if found then table.clone(found.versions) else {}
		end,

		version = function(_: Backend, store: string, key: string, id: string): Version?
			const found = entry(store, key)
			if found then
				for _, version in found.versions do
					if version.id == id then
						return version
					end
				end
			end
			return nil
		end,
	}
	return self
end

return Backend
