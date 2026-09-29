--!strict
--- What the simulator needs from a profile library, so the same scenarios drive ProfileStore now and
--- KeepBlox later. An adapter translates one library's API into this shape; it never adds behaviour.

--> The live data of a simulated player. Each session has its own tag in `p` and counts its steps of
--> play there, so a save tells exactly which progress it holds, and a lost write shows as a count that
--> went back.
export type Data = { p: { [string]: number } }

export type Hooks = {
	--> The library confirmed that `saved` (a copy of the data) is what the store holds.
	acked: (saved: Data) -> (),
	--> The session ended, for any reason (released, lost to another server, shut down).
	ended: () -> (),
	--> True once the player left while the open was still in progress.
	cancelled: () -> boolean,
}

export type Session = {
	data: Data,
	isActive: () -> boolean,
	--> Ends the session: a final save and the lock released. May yield.
	release: () -> (),
}

export type Library = {
	--> Opens the session for `key`, yielding until it is open or has failed (nil).
	open: (key: string, hooks: Hooks) -> Session?,
}

--> Where a library keeps things in a stored value, so the ledger can check any library's writes.
export type Format = {
	--> The player data a stored value holds, or nil.
	data: (value: any) -> Data?,
	--> The lock a stored value records: the JobId holding it (nil when free) and its load count.
	--> Nil for a library that keeps no lock in the value (none at all, or one in MemoryStore): the
	--> `foreign-write` and `load-count-backwards` checks do not apply to it then.
	lock: ((value: any) -> { job: string?, loadCount: number? })?,
	--> The player data `key` holds now, read from the simulated world (its data stores and ordered
	--> stores), for a library whose data does not live at the key itself.
	current: ((world: any, key: string) -> Data?)?,
}

export type Adapter = {
	name: string,
	--> The data store the library keeps profiles in, for the ledger's checks.
	store: string,
	--> How the library stores a profile; ProfileStore's record by default.
	format: Format?,
	--> Starts the library on one server. It runs in a thread of that server.
	boot: (env: any) -> Library,
}

--> ProfileStore's record (`{Data, MetaData = {ActiveSession, SessionLoadCount}}`), which KeepBlox keeps.
const PROFILE_STORE: Format = {
	data = function(value: any): Data?
		return if type(value) == "table" and type(value.Data) == "table" then value.Data else nil
	end,
	lock = function(value: any): { job: string?, loadCount: number? }
		const meta = if type(value) == "table" then value.MetaData else nil
		if type(meta) ~= "table" then
			return { job = nil, loadCount = nil }
		end
		const owner = meta.ActiveSession
		return { job = if type(owner) == "table" then owner[2] else nil, loadCount = meta.SessionLoadCount }
	end,
}

return { PROFILE_STORE = PROFILE_STORE }
