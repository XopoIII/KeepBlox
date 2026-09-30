--!strict
--- The shapes a store and its sessions share (see Session, which holds the behaviour).
const Codec = require("./Codec")
const Config = require("./Config")
const Inbox = require("./Inbox")
const Migrate = require("./Migrate")
const Profile = require("./Profile")
const Record = require("./Record")
const Serial = require("./Serial")
const Services = require("./Services")

export type Context = {
	--> The store's name (its data store).
	storeName: string,
	services: Services.Services,
	config: Config.Config,
	dataStore: Services.DataStore,
	identity: Record.Identity,
	--> Reports a problem with a key; the store turns it into its `onError` signal.
	report: (key: string, message: string) -> (),
	--> True once the server began shutting down.
	closing: () -> boolean,
	--> The schema and migrations the data follows.
	plan: Migrate.Plan,
	--> Called once when a session ends, so the store can forget it.
	forget: (session: Session) -> (),
	--> Called after each save stored the data (`final` on the release): the leaderboards' mirror.
	stored: ((key: string, data: any, final: boolean) -> ())?,
	--> Large profiles are stored compressed (see Codec).
	compress: Codec.Options?,
	--> This server's MemoryStore beat is landing (see Lease); every write tells newcomers so.
	beating: (() -> boolean)?,
	--> A load's: the time (`clock.now()`) it must answer by, one deadline for all its steps (see Open).
	deadline: number?,
}

export type Session = {
	key: string,
	loadCount: number,
	profile: Profile.Profile,
	--> The context this session writes with: the store's, with this session's own identity.
	context: Context,
	active: boolean,
	--> True from the moment a release begins: the data is frozen then, so the final save holds every
	--> change the game made.
	releasing: boolean,
	--> The canonical text of the data as last stored.
	storedText: string,
	storedSize: number,
	lastDataWrite: number,
	nextRenew: number,
	serial: Serial.Serial,
	--> The last validation problem reported, so it is not reported on every renewal.
	lastProblem: string?,
	--> The incoming messages and their handlers.
	inbox: Inbox.Inbox,
	--> Save at the next tick, not at the next renewal: a message was processed, or someone sent one.
	saveSoon: boolean,
	--> Purchase receipt ids granted into the data, the ones not yet stored included (see Receipts).
	receipts: { string },
	--> The receipt ids the store is known to hold.
	storedReceipts: { [string]: boolean },
	--> The hand-over subscription, set up before the claim; `done` once the session ended.
	listener: { session: Session?, connection: Services.Connection?, done: boolean },
	--> A manual save waiting in the lane that has not taken its snapshot yet. Later calls join it:
	--> its snapshot will hold their changes, so a game calling `save` in a loop makes one write, not
	--> a queue of them.
	pending: Pending?,
	--> The record holds a settled trade's journal: the next write that stores this data clears it.
	clearJournal: boolean,
	--> Snapshots of the data in this server's MemoryStore entry (see Lease): the number of the latest,
	--> and its text. A write records the number, so a snapshot newer than the stored data is known.
	snapSeq: number,
	snapText: string,
	--> The last beat carried a snapshot of this session: it may write at `renew`, not `renewFallback`.
	snapshotted: boolean,
	--> A trade holds this session's data: no snapshot may catch it half-changed.
	trading: boolean,
	--> The latest snapshot that could be stored, with what went with it: what a write stores when the
	--> data in memory can no longer be (see Lease).
	good: Good?,
}

export type Pending = { done: boolean, stored: boolean, waiters: { thread } }

--> The last snapshot that could be stored: `data` as stored (at the plan's `write` version), `play` as
--> the game has it (at its `version`; the same table when the two are one).
export type Good = {
	text: string,
	size: number,
	data: any,
	play: any,
	consumed: { [number]: boolean },
	receipts: { string },
}

-- Types only: a module must still return one value.
return {}
