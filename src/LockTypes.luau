--!strict
--- The types of the lock's transforms (see Lock), kept apart so the transforms fit in one file.
const Owed = require("./Owed")
const Record = require("./Record")

export type Owner = {
	session: Record.Session,
	--> Our lease number, when the owner is a KeepBlox session; nil for a ProfileStore owner.
	lease: number?,
	lastUpdate: number?,
	loadCount: number,
	--> The owner beats in MemoryStore (see Lease).
	memory: boolean,
}

--> How a claim treats a key someone else holds.
export type Mode = {
	--> Take the key from whoever holds it, at once (ProfileStore's `Steal = true`).
	force: boolean?,
	--> Never ask for a hand-over: a held key is left untouched, no `ForceLoadSession` is written.
	quiet: boolean?,
	--> With `quiet`: take a held key only while its owner is still this session at this lease, which
	--> the caller watched long enough to know it is dead.
	expect: Expected?,
	--> An importer's reader (see Import): a value that is not a profile is converted, not quarantined,
	--> when the reader recognises it. A value the old library still holds is left alone.
	adopt: ((value: any, info: any, now: number) -> { kind: string, data: any?, userIds: { number }? })?,
	--> The importer's name, recorded in a profile made from imported data.
	imported: string?,
	--> The template is data imported from elsewhere (not a new player's defaults).
	fromImport: boolean?,
	--> UserIds for a profile made from data imported from elsewhere.
	userIds: { number }?,
	--> This server beats in MemoryStore: the record says so, for newcomers (see Lease).
	memory: boolean?,
	--> The schema version a new profile's data is at: the template is written for the current schema,
	--> so no migration may run on it. Imported data gets none (it is from before every migration).
	version: number?,
	--> A steal on the word of the owner's MemoryStore beat: it lands only while the record still says
	--> the owner beats. An owner whose beats stop landing says otherwise first (see Upkeep.beat).
	byBeat: boolean?,
}

--> The owner a quiet claim watched long enough to know it is dead. `byBeat`: it was judged by its beat,
--> which the record must still vouch for.
export type Expected = { guid: string, loadCount: number, lease: number?, byBeat: boolean? }

--> The session a claim recovers from: the one it took the key from, or one noted in the record.
export type Previous = Owed.Previous

export type Payload = {
	--> The data to store, or nil to keep what is stored (a lease renewal).
	data: any?,
	userIds: { number }?,
	robloxMetaData: any?,
	--> Clears ActiveSession: the session ends with this write.
	release: boolean,
	--> Messages processed into `data`, removed from the queue by this same write.
	consumed: { [number]: boolean }?,
	--> Purchase receipt ids granted into `data`, stored by this same write.
	receipts: { string }?,
	--> The schema version `data` is at, stored with it.
	schemaVersion: number?,
	--> An open trade's journal, stored with `data` (see Trade); false clears it.
	journal: any?,
	--> Whether this server's MemoryStore beat can be trusted now (see Lease).
	memory: boolean?,
	--> The session's latest MemoryStore snapshot number, stored with the data (see Lease).
	snap: number?,
	--> With `release`: the owner this session took the key from, whose last beat it could not store.
	owed: Previous?,
	--> `Once.stamp()`, taken once per write (the same for its tries): a write whose stamp is not above
	--> the stored one, for this load, changes nothing (see Once). Nil: not fenced.
	stamp: number?,
}

return {}
