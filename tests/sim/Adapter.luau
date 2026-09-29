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

export type Adapter = {
	name: string,
	--> The data store the library keeps profiles in, for the ledger's checks.
	store: string,
	--> Starts the library on one server. It runs in a thread of that server.
	boot: (env: any) -> Library,
}

return {}
