--!strict
--- The seam: every Roblox service the library uses, reached through one bundle.
---
--- These types are ours and deliberately narrow. The library only ever calls what is listed here, so
--- the test harness can hand in fakes (`tests/fakes/`) and the real adapter (`RobloxServices`) can
--- translate. Method names and return shapes follow Roblox, so code written against the seam reads
--- like code written against the engine; where Roblox takes an options Instance, the seam takes plain
--- values instead (`useCache`, `metadata`).
---
--- Roblox reference: https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore

--> What `DataStoreKeyInfo` exposes. Times are Unix milliseconds.
export type KeyInfo = {
	CreatedTime: number,
	UpdatedTime: number,
	Version: string,
	GetUserIds: (self: KeyInfo) -> { number },
	GetMetadata: (self: KeyInfo) -> { [string]: any },
}

--> An `UpdateAsync` transform. It must not yield, it may run more than once, and returning nil
--> cancels the write. UserIds and metadata that are not returned are CLEARED, as in Roblox.
export type Transform = (current: any, keyInfo: KeyInfo?) -> (any, { number }?, { [string]: any }?)

--> One entry of `ListVersionsAsync`. `CreatedTime` is Unix milliseconds.
export type VersionInfo = {
	Version: string,
	CreatedTime: number,
	IsDeleted: boolean,
}

--> `DataStoreVersionPages`.
export type VersionPages = {
	IsFinished: boolean,
	GetCurrentPage: (self: VersionPages) -> { VersionInfo },
	AdvanceToNextPageAsync: (self: VersionPages) -> (),
}

export type DataStore = {
	--> (value, keyInfo), or (nil, nil) when the key is absent or its latest version is deleted.
	--> `useCache` defaults to true: a read within 4 s of the last one returns the cached value.
	GetAsync: (self: DataStore, key: string, useCache: boolean?) -> (any, KeyInfo?),
	--> Returns the id of the version written.
	SetAsync: (
		self: DataStore,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	) -> string,
	--> (new value, keyInfo) once written.
	UpdateAsync: (self: DataStore, key: string, transform: Transform) -> (any, KeyInfo?),
	--> Marks the key deleted; returns the value and keyInfo it had, or (nil, nil).
	RemoveAsync: (self: DataStore, key: string) -> (any, KeyInfo?),
	ListVersionsAsync: (
		self: DataStore,
		key: string,
		ascending: boolean?,
		minDate: number?,
		maxDate: number?,
		pageSize: number?
	) -> VersionPages,
	GetVersionAsync: (self: DataStore, key: string, version: string) -> (any, KeyInfo?),
}

--> One entry of a sorted page: a key and its integer value.
export type SortedEntry = { key: string, value: number }

--> `DataStorePages` of `GetSortedAsync`.
export type SortedPages = {
	IsFinished: boolean,
	GetCurrentPage: (self: SortedPages) -> { SortedEntry },
	AdvanceToNextPageAsync: (self: SortedPages) -> (),
}

--> `OrderedDataStore`: an integer per key, readable in sorted pages (leaderboards).
--> https://create.roblox.com/docs/reference/engine/classes/OrderedDataStore
export type OrderedDataStore = {
	GetAsync: (self: OrderedDataStore, key: string) -> number?,
	SetAsync: (self: OrderedDataStore, key: string, value: number) -> (),
	--> `transform` gets the current value (nil when absent) and returns the new one, or nil to cancel.
	UpdateAsync: (self: OrderedDataStore, key: string, transform: (current: number?) -> number?) -> number?,
	RemoveAsync: (self: OrderedDataStore, key: string) -> number?,
	GetSortedAsync: (
		self: OrderedDataStore,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?
	) -> SortedPages,
}

--> The modern `Enum.DataStoreRequestType` values: standard and ordered data stores.
export type RequestType =
	"StandardRead"
	| "StandardWrite"
	| "StandardList"
	| "StandardRemove"
	| "OrderedRead"
	| "OrderedWrite"
	| "OrderedList"
	| "OrderedRemove"

export type DataStoreService = {
	GetDataStore: (self: DataStoreService, name: string, scope: string?) -> DataStore,
	GetOrderedDataStore: (self: DataStoreService, name: string, scope: string?) -> OrderedDataStore,
	GetRequestBudgetForRequestType: (self: DataStoreService, requestType: RequestType) -> number,
}

--> What a MessagingService subscriber receives. `Sent` is the sender's Unix time in seconds.
export type Message = { Data: any, Sent: number }

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Messaging = {
	--> Yields until the backend has the message. Delivery is best effort.
	PublishAsync: (self: Messaging, topic: string, message: any) -> (),
	--> Yields until the subscription is registered.
	SubscribeAsync: (self: Messaging, topic: string, callback: (message: Message) -> ()) -> Connection,
}

--> Time and threads. `now()` is monotonic seconds (`os.clock`); `time()` is this server's wall clock
--> in whole Unix seconds (`os.time`), which other servers' clocks do not agree with.
export type Clock = {
	now: () -> number,
	time: () -> number,
	--> Yields for `dt` seconds (none: one frame's worth of yield); returns the time actually waited.
	wait: (dt: number?) -> number,
	--> `task.spawn`: runs a function, or resumes a suspended thread, at once until it first yields.
	spawn: (target: thread | (...any) -> (), ...any) -> (),
}

--> Serializing and compressing data, for a store that compresses large profiles.
export type Codec = {
	--> JSON text of a storable value (`HttpService:JSONEncode`), and back (`JSONDecode`).
	encode: (value: any) -> string,
	decode: (text: string) -> any,
	--> Zstandard (`EncodingService:CompressBuffer`), and back (`DecompressBuffer`).
	compress: (text: string) -> buffer,
	decompress: (packed: buffer) -> string,
}

export type Services = {
	--> Serialization and compression; nil where there is none (a store cannot compress then).
	codec: Codec?,
	dataStores: DataStoreService,
	messaging: Messaging,
	clock: Clock,
	placeId: number,
	jobId: string,
	--> True in Studio. The library then never touches a live key unless API access is on.
	isStudio: boolean,
	--> `game:BindToClose`: `callback` runs, in its own thread, when the server shuts down.
	bindToClose: (callback: () -> ()) -> (),
	--> A new unique id (`HttpService:GenerateGUID(false)`): one per session, as ProfileStore uses.
	guid: () -> string,
}

-- Types only: a module must still return one value.
return {}
