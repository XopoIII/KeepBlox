--!strict
--- In-memory data stores and messaging, for Studio without API access and for scratch play tests.
---
--- It wraps a real `Services` and replaces only `dataStores` and `messaging`; the clock, shutdown and
--- GUIDs stay the engine's. Values are deep-copied on every write and read, as a real store
--- serializes them, so game code can never hold a reference into "stored" data. Nothing here ever
--- reaches a live key. Each name keeps its own set of stores, so separate scratch sessions stay
--- separate within one play test.
const Record = require("./Record")
const Services = require("./Services")

type Entry = { value: any, version: number, userIds: { number }, metadata: { [string]: any }, updatedMs: number }

const MockServices = {}

-- Every scratch set, by name, for the lifetime of the server.
const sets: { [string]: { [string]: { [string]: Entry } } } = {}

const function keyInfo(entry: Entry): Services.KeyInfo
	return {
		CreatedTime = entry.updatedMs,
		UpdatedTime = entry.updatedMs,
		Version = tostring(entry.version),
		GetUserIds = function(_: Services.KeyInfo): { number }
			return table.clone(entry.userIds)
		end,
		GetMetadata = function(_: Services.KeyInfo): { [string]: any }
			return table.clone(entry.metadata)
		end,
	}
end

const function store(entries: { [string]: Entry }, clock: Services.Clock): Services.DataStore
	const function write(key: string, value: any, userIds: { number }?, metadata: { [string]: any }?): Entry
		const previous = entries[key]
		const entry: Entry = {
			value = Record.copy(value),
			version = if previous then previous.version + 1 else 1,
			userIds = table.clone(userIds or {}),
			metadata = table.clone(metadata or {}),
			updatedMs = clock.time() * 1000,
		}
		entries[key] = entry
		return entry
	end

	const unsupported = function(): never
		error("KeepBlox mock: versions are not kept in memory", 2)
	end

	const handle = {}
	function handle.GetAsync(_: Services.DataStore, key: string): (any, Services.KeyInfo?)
		const entry = entries[key]
		if entry == nil then
			return nil, nil
		end
		return Record.copy(entry.value), keyInfo(entry)
	end
	function handle.SetAsync(
		_: Services.DataStore,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	): string
		return tostring(write(key, value, userIds, metadata).version)
	end
	function handle.UpdateAsync(
		_: Services.DataStore,
		key: string,
		transform: Services.Transform
	): (any, Services.KeyInfo?)
		const entry = entries[key]
		const current = if entry then Record.copy(entry.value) else nil
		const value, userIds, metadata = transform(current, if entry then keyInfo(entry) else nil)
		if value == nil then
			return nil, nil
		end
		const written = write(key, value, userIds, metadata)
		return Record.copy(written.value), keyInfo(written)
	end
	function handle.RemoveAsync(_: Services.DataStore, key: string): (any, Services.KeyInfo?)
		const entry = entries[key]
		entries[key] = nil
		if entry == nil then
			return nil, nil
		end
		return Record.copy(entry.value), keyInfo(entry)
	end
	handle.ListVersionsAsync = unsupported :: any
	handle.GetVersionAsync = unsupported :: any
	return handle :: Services.DataStore
end

--> `base` with its data stores and messaging kept in memory, in the scratch set `name`.
function MockServices.wrap(base: Services.Services, name: string): Services.Services
	local set = sets[name]
	if not set then
		set = {}
		sets[name] = set
	end
	const stores = set :: { [string]: { [string]: Entry } }
	const handles: { [string]: Services.DataStore } = {}

	const dataStores = {}
	function dataStores.GetDataStore(
		_: Services.DataStoreService,
		storeName: string,
		scope: string?
	): Services.DataStore
		const id = `{storeName}/{scope or "global"}`
		if not handles[id] then
			stores[id] = stores[id] or {}
			handles[id] = store(stores[id], base.clock)
		end
		return handles[id]
	end
	function dataStores.GetRequestBudgetForRequestType(
		_: Services.DataStoreService,
		_requestType: Services.RequestType
	): number
		return math.huge
	end

	const listeners: { [string]: { (Services.Message) -> () } } = {}
	const messaging = {}
	function messaging.PublishAsync(_: Services.Messaging, topic: string, data: any)
		for _, listener in table.clone(listeners[topic] or {}) do
			base.clock.spawn(listener, { Data = Record.copy(data), Sent = base.clock.time() })
		end
	end
	function messaging.SubscribeAsync(
		_: Services.Messaging,
		topic: string,
		callback: (Services.Message) -> ()
	): Services.Connection
		const list = listeners[topic] or {}
		listeners[topic] = list
		table.insert(list, callback)
		return {
			Disconnect = function(_: Services.Connection)
				const index = table.find(list, callback)
				if index then
					table.remove(list, index)
				end
			end,
		}
	end

	const wrapped = table.clone(base)
	wrapped.dataStores = dataStores :: Services.DataStoreService
	wrapped.messaging = messaging :: Services.Messaging
	return wrapped
end

--> Whether an error from a real data store call means Studio has no access to live data.
function MockServices.isNoAccess(message: string): boolean
	return string.find(message, "403", 1, true) ~= nil
		or string.find(message, "must publish", 1, true) ~= nil
		or string.find(message, "API access", 1, true) ~= nil
end

return MockServices
