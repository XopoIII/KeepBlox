--!strict
--- What a store's `onError` fires with: `(key, message, kind)`.
---
--- `message` is prose for a log, and may name the key. `kind` is one word from the fixed list below,
--- and never holds a key, an id or anything else from the data: a game can count it, put it in an
--- analytics row, or tell a failed save from a failed leaderboard write without reading the message.
---
--- | kind | What happened |
--- |---|---|
--- | `"save"` | A write of an open profile failed: a save, a renewal, or one whose caller was cancelled |
--- | `"refused"` | The data could not be stored (a value, the schema, the size); the last good save stays |
--- | `"repair"` | The data was stored with a value repaired, and the path of the repair is named |
--- | `"load"` | A try of a load failed, or a load failed after its caller was cancelled |
--- | `"migration"` | A load found data it cannot use: a newer schema, a migration that threw, or data off the schema |
--- | `"release"` | A key was not given back, or not let go of, or was freed for the server asking for it |
--- | `"snapshot"` | A dead server's last heartbeat could not be used or stored, so the stored data is used |
--- | `"quarantine"` | The stored value is not a profile: it was copied aside and left untouched |
--- | `"leaderboard"` | A leaderboard's read function threw, or its ordered data store was not written |
--- | `"receipt"` | A purchase has no grant, or its grant threw; it is answered `NotProcessedYet` |
--- | `"message"` | A message was refused or not sent, or a message handler threw |
--- | `"import"` | A read from the library being moved from failed, and is tried again |
--- | `"studio"` | Studio keeps the data in memory, or could not read a live profile to copy |
--- | `"schedule"` | A scheduled job was stored but not indexed, or its handler threw |
--- | `"tally"` | A tally's batch was not written, a watched key was not read, or a shard holds something else |
---
--- A kind is added only in a release that says so in its changelog; none is ever renamed or removed.

export type ErrorKind =
	"save"
	| "refused"
	| "repair"
	| "load"
	| "migration"
	| "release"
	| "snapshot"
	| "quarantine"
	| "leaderboard"
	| "receipt"
	| "message"
	| "import"
	| "studio"
	| "schedule"
	| "tally"

--> Hears of a problem: the store's `onError`. Every site names its kind; none can leave it out.
export type Report = (key: string, message: string, kind: ErrorKind) -> ()

-- Types only: a module must still return one value.
return {}
