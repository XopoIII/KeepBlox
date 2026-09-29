--!strict
--- Ready importers for the libraries games move from (see Import). Each reads the old library's value
--- exactly as that library stores it, and treats its lock by that library's own rule.
---
---     import = KeepBlox.importers.DocumentService({ store = "PlayerData" })
---     import = KeepBlox.importers.DataStore2({ name = "DATA", userId = function(key) return tonumber(key:sub(3)) end })
---
--- Every importer takes:
--- - `store` (and `scope`): the old data store. Omit `store` when KeepBlox uses the same store and keys;
---   the old value is then converted in place, inside the claim;
--- - `key`: the old key for a KeepBlox key (the same key by default);
--- - `convert`: shapes the old data into this store's (the old data as is by default). The result must
---   be a table. Migrations then run on it from version 0.
const Import = require("./Import")
const Services = require("./Services")

export type Options = {
	store: string?,
	scope: string?,
	key: ((key: string) -> string)?,
	convert: ((data: any) -> any)?,
	--> Seconds after which the old library itself treats its lock as dead; its own default otherwise.
	lockSeconds: number?,
}

const Importers = {}

-- Builds an importer over `read`, which turns an old value into Found (without `convert`).
const function build(
	name: string,
	options: Options,
	read: (value: any, info: Services.KeyInfo?, now: number, lockSeconds: number) -> Import.Found,
	defaultLock: number
): Import.Importer
	assert(type(options) == "table", `KeepBlox: importers.{name} needs options`)
	const lockSeconds = options.lockSeconds or defaultLock
	const convert = options.convert
	const keyOf = options.key or function(key: string): string
		return key
	end
	const store = options.store
	return {
		name = name,
		fetch = if store
			then function(services: Services.Services, key: string): (any, Services.KeyInfo?)
				return services.dataStores:GetDataStore(store, options.scope):GetAsync(keyOf(key), false)
			end
			else nil,
		read = function(value: any, info: Services.KeyInfo?, now: number): Import.Found
			const found = read(value, info, now, lockSeconds)
			if found.kind ~= "data" then
				return found
			end
			const data = if convert then convert(found.data) else found.data
			if type(data) ~= "table" then
				return { kind = "unknown" }
			end
			return { kind = "data", data = data, userIds = found.userIds }
		end,
	}
end

--> Suphi's DataStore Module: the value is the game's own data, stored as is; the lock lives in
--> MemoryStore, which the importer cannot see, so every old server must be gone first. A value the
--> module compressed needs `decode(value, metadata)`.
function Importers.Suphi(
	options: Options & { decode: ((value: any, metadata: { [string]: any }) -> any)? }
): Import.Importer
	const decode = options.decode
	return build("Suphi", options, function(value: any, info: Services.KeyInfo?): Import.Found
		const data = if decode then decode(value, if info then info:GetMetadata() else {}) else value
		return if type(data) == "table" then { kind = "data", data = data } else { kind = "unknown" }
	end, 0)
end

--> DocumentService: `{data, sessionLockId, lockTimestamp, isLocked, dataSchemaVersion, ...}`; a lock
--> older than 600 s (its LOCK_EXPIRE) is dead.
function Importers.DocumentService(options: Options): Import.Importer
	return build(
		"DocumentService",
		options,
		function(value: any, _: any, now: number, lockSeconds: number): Import.Found
			if type(value) ~= "table" or value.data == nil or value.documentServiceSchemaVersion == nil then
				return { kind = "unknown" }
			end
			if
				value.isLocked == true
				and type(value.lockTimestamp) == "number"
				and now - value.lockTimestamp < lockSeconds
			then
				return { kind = "locked" }
			end
			return { kind = "data", data = value.data }
		end,
		600
	)
end

--> Lapis: `{migrationVersion, lastCompatibleVersion, lockId, data}`; a lock is dead 30 minutes after
--> the key was last updated.
function Importers.Lapis(options: Options): Import.Importer
	return build(
		"Lapis",
		options,
		function(value: any, info: Services.KeyInfo?, now: number, lockSeconds: number): Import.Found
			if type(value) ~= "table" or value.data == nil or value.migrationVersion == nil then
				return { kind = "unknown" }
			end
			if value.lockId ~= nil and (info == nil or now * 1000 - info.UpdatedTime < lockSeconds * 1000) then
				return { kind = "locked" }
			end
			return { kind = "data", data = value.data, userIds = if info then info:GetUserIds() else nil }
		end,
		1800
	)
end

--> DataKeep: `{Data, Metadata = {ActiveSession, LastUpdate, LoadCount}, GlobalUpdates, UserIds}`; a
--> session with no update for 600 s (its assumeDeadLock) is dead.
function Importers.DataKeep(options: Options): Import.Importer
	return build("DataKeep", options, function(value: any, _: any, now: number, lockSeconds: number): Import.Found
		const meta = if type(value) == "table" then value.Metadata else nil
		if type(value) ~= "table" or type(value.Data) ~= "table" or type(meta) ~= "table" then
			return { kind = "unknown" }
		end
		if meta.ActiveSession ~= nil and type(meta.LastUpdate) == "number" and now - meta.LastUpdate < lockSeconds then
			return { kind = "locked" }
		end
		return { kind = "data", data = value.Data, userIds = value.UserIds }
	end, 600)
end

--> DataStore2, by its saving method: "OrderedBackups" (its default: the newest of numbered saves in
--> data store "<name>/<UserId>", indexed by the ordered store of that name) or "Standard" (data store
--> `name`, key UserId). `name` is the store's name, or the master key of `DataStore2.Combine`. It has
--> no lock: every old server must be gone first.
function Importers.DataStore2(options: Options & {
	name: string,
	userId: (key: string) -> number?,
	method: ("OrderedBackups" | "Standard")?,
}): Import.Importer
	assert(type(options.name) == "string", "KeepBlox: importers.DataStore2 needs the store name")
	assert(type(options.userId) == "function", "KeepBlox: importers.DataStore2 needs userId(key)")
	const importer = build("DataStore2", options, function(value: any): Import.Found
		return if type(value) == "table" then { kind = "data", data = value } else { kind = "unknown" }
	end, 0)
	const method = options.method or "OrderedBackups"
	importer.fetch = function(services: Services.Services, key: string): (any, Services.KeyInfo?)
		const userId = options.userId(key)
		if userId == nil then
			return nil, nil
		end
		if method == "Standard" then
			return services.dataStores:GetDataStore(options.name):GetAsync(tostring(userId), false)
		end
		const name = `{options.name}/{userId}`
		const newest = services.dataStores:GetOrderedDataStore(name):GetSortedAsync(false, 1):GetCurrentPage()[1]
		if newest == nil then
			return nil, nil
		end
		return services.dataStores:GetDataStore(name):GetAsync(tostring(newest.value), false)
	end
	return importer
end

--> Any other library: `read(value, keyInfo, now)` returns what Import.Found says; `fetch` reads the old
--> value (omit it for the same key of this store).
function Importers.custom(importer: Import.Importer): Import.Importer
	assert(
		type(importer.name) == "string" and type(importer.read) == "function",
		"KeepBlox: an importer needs name and read"
	)
	return importer
end

return Importers
