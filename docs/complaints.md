# What users of other data libraries run into, and where KeepBlox stands

Collected on 2026-09-29 from the GitHub issues (open and closed) and the DevForum threads of
ProfileStore, ProfileService, DataStore2, Suphi's DataStore Module, Lapis, DataKeep and DocumentService.
Every row names its source and the spec that proves KeepBlox's answer. A row without a spec is not
closed.

Sources: `PS` MadStudioRoblox/ProfileService, `PStore` MadStudioRoblox/ProfileStore, `DS2`
Kampfkarren/Roblox, `Lapis` nezuo/lapis, `DataKeep` noahrepublic/DataKeep, `DocS`
anthony0br/DocumentService (`#n` is a GitHub issue). DevForum threads: ProfileService
[t/667805](https://devforum.roblox.com/t/667805), ProfileStore [t/3190543](https://devforum.roblox.com/t/3190543),
Suphi [t/2425597](https://devforum.roblox.com/t/2425597) (`pN #m` is page N, post m).

## Locks and waits

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| 60-90 s wait for the lock after a server hop or auto-reconnect | PS#41, PS p60 #1274 | a live owner hands over on request in about a second (through MemoryStore when MessagingService is down); a dead server is known by its MemoryStore beat, and its keys are taken within about 12 s | `tests/unit/Lease.luau`, `bench/Benchmarks.md` |
| Kicked after a manual save | PStore p8 #153 | a save never ends or re-claims the session | `Complaints: a manual save does not end the session` |
| Lock kept after a failed load or close; player locked out | Lapis#30, Lapis#46 | a failed or cancelled load gives the key back; a failed migration too | `Complaints: a load in flight when shutdown begins gives the key back`, `Store: a cancelled load gives the key back` |
| Every load became a force-load | DataKeep#6 | the claim transform decides from the record alone | `tests/unit/Lock.luau` |
| An autosave in flight re-locks the key after close | DocS#119, DocS#125 | one write lane per profile; a released session never writes again | `Complaints: an autosave in flight never re-locks a released key` |
| Quick rejoin into the same server: "Document not open" / stale closed document | DocS#126, DataKeep#21 | the load waits for this server's own release, then claims afresh | `Complaints: a quick rejoin into the same server waits for the release` |

## Silent loss or overwrite

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| A failed read loads the template over saved data | PStore p10 #195/#203 | a load is one `UpdateAsync` transform; a failure retries and never writes | `Complaints: a failed read never loads the template over saved data` |
| `Set` without `Get` wipes data; no lock, a second device loses changes | DS2#152, DS2#144 | session lock on every key; a value that is not a profile is quarantined | `Store: a value that is not a profile is quarantined` |
| Reading an old version overwrote live data | DataKeep#22 | `readVersion` returns a copy and never writes | `Complaints: reading an old version never changes the live profile` |
| Autosave after a failed migration | DocS#90 | a failed migration gives the key back and writes nothing | `tests/unit/Migrate.luau` |
| Number keys silently became strings | Lapis#68 | a table that is neither an array nor a string-keyed dictionary is refused, with its path | `Validate: every refusal names the path of the bad value` |
| Data lost past 4 MB | PS p40 #848, PS#24 | refused before the write, naming the field that grew; the last save stays | `Complaints: a profile over the size limit is refused with its path` |

## Shutdown

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| Saves lost when the game's own BindToClose competes | PStore p5 #104 | releases run in parallel and retry until the deadline | `Complaints: a game BindToClose that spends the budget does not cost saves` |
| Loads accepted during shutdown | DS2#126, Lapis#37 | refused with "closing", nothing written | `Complaints: a load after shutdown began is refused` |
| BindToClose yields forever or always waits 30 s | DocS#51, DocS#48 | it waits only for pending releases, at most `shutdownDeadline` | `Store: shutdown releases every profile in parallel` |

## Throttling, leaks, speed

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| The library's own save queue grows without bound | Lapis#41 | manual saves join the one waiting; renewals skip a busy lane and wait for budget | `Complaints: a save loop becomes a few writes` |
| Memory leak per player; loads slow after an hour | DS2#124, PS p40 #851 | nothing is kept after a release: no profile, subscription or thread | `Complaints: 300 joins and leaves leave nothing behind` |
| Loads delayed when many players join at once | PStore p10 #207 | loads do not wait on each other | `Complaints: 50 players joining at once all load quickly` |
| Viewing profiles blocks loads | PS p60 #1270 | support reads do not share the load path | `Complaints: reading versions does not hold up loads` |

## Data shape

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| Reconcile is manual and shallow | Suphi p11 #213, PStore#9 | a template store fills missing keys deeply on every load; a schema store fills its defaults | `Complaints: new template keys reach old profiles, deeply` |

## Support, admin and Studio

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| No way to edit offline players (bans, gifts, bulk fixes) | PS#48, PS p40 #834, DocS#58 | `store:edit(key, fn)`: edits in place when open here, claims quietly when nobody holds the key, "inUse" (and a `store:message`) when a live server does; never kicks | `tests/unit/Edit.luau` |
| An edit that fails half-way leaves broken data | DocS#92 | an edit that throws or cannot be stored is undone and nothing is written | `Edit: an edit that throws writes nothing` |
| Want Studio play tests that never save | PStore p6 #113, DocS#65 | `studio = "memory"` | `Mock: studio = memory never touches live data` |
| Want to test against real profiles without touching them | PStore p6 #113 | `studio = "copy"`: live data read once, unlocked, kept in memory | `Mock: studio = copy starts from the live data` |
| Studio with API access writes a probe to a live key | PStore findings | the access check only reads | `Mock: Studio without API access falls back to memory` |

## Migration

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| Moving from ProfileService is blocked (scope removed) | PStore p5 #99, p8 #156 | ProfileStore and ProfileService records load as they are; `importers.*` take `scope` | `tests/scenario/Compat.luau`, `tests/unit/Import.luau` |
| No way off DataStore2, DocumentService, Lapis, DataKeep or Suphi's module | DS2#147 | `KeepBlox.importers`: each key moves on its first load, the old value is only read, the old lock is honoured | `tests/unit/Import.luau` |
| A failed read during a move starts the player from scratch | PStore p10 #195 | a failed read of the old store is retried until the load times out; nothing is written meanwhile | `Import: a failed read of the old store is retried` |
| Migrations must be safe to write and test | DocS#90, DocS#91 | numbered migrations, `KeepBlox.migrate` for fixtures; a new player's template is never migrated; imported data runs every migration | `tests/unit/Migrate.luau` |

## Features users keep asking for

| Request | Source | KeepBlox | Spec |
|---|---|---|---|
| Leaderboards beside the profiles | PS#33, PStore p5 #87/#101 (declined there) | `leaderboards` option: chosen numbers mirrored to ordered data stores within the OrderedWrite budget; `store:leaderboard` reads the top, cached | `tests/unit/Boards.luau` |
| Atomic trades between players | DocS#127, ProfileStore findings #9 | `store:trade(a, b, fn)`: both or neither, whatever dies when, via a trade record and journals | `tests/unit/Trade.luau` (a crash after every write, a lost answer, 40 seeds of failures) |
| Shared, unlocked documents (guilds, clans, global keys) | Lapis#58, DocS#89, PStore p3 #55-59 | `KeepBlox.shared`: `update` in one UpdateAsync from any server, `watch` for changes | `tests/unit/Shared.luau` |
| Compression for large profiles | PStore#7, DocS#112, PS#24 | `compress = { above = n }`, Zstandard through EncodingService; opt-in because ProfileStore cannot read it | `tests/unit/Codec.luau` |
| Rollback to an old version | PStore p6 #108, DataKeep#4 | `versions`, `readVersion`, `restore` (refused while a server holds the key) | `tests/unit/Versions.luau` |
| Saved / ended / error signals | PS#5, PS#11, DocS#107, Lapis#38 | `onSaving`, `onSaved`, `onEnded(reason)`, `store.onError` | `tests/unit/Store.luau` |
| UserIds for GDPR | DS2#143, Lapis#21 | `addUserId` / `removeUserId`, kept through imports | `tests/unit/Import.luau` |
| Read-only views that cannot corrupt live data | Lapis#44, DataKeep#22 | `readVersion` returns a copy; `load(key, { quiet = true })` never kicks | `tests/unit/Edit.luau` |

## Types, testing, distribution

| Complaint | Source | KeepBlox | Spec |
|---|---|---|---|
| Wrong or missing Luau types | PS#23, PStore p8 #162, DataKeep#31, Suphi p7 #124 | `--!strict` everywhere, checked with the new solver on every commit | `scripts/type-check.sh` |
| roblox-ts declarations missing or stale | PStore#12 | `types/index.d.ts`, checked against the Luau API | `tests/unit/Typings.luau` |
| Mock mode breaks or hangs | PS#34, PS#7, DataKeep#24 | `mock = true` / a scratch name: the same code over in-memory stores | `tests/unit/Mock.luau` |
| No way to test shutdown | DocS#80 | `store:close()` does what BindToClose does | `Mock: a test can close a store as a shutdown would` |
| No official Wally / pesde package | PS#25, PStore#21, PStore#10 | planned for the first release (M6) | none yet: open |

## Not KeepBlox's problem, and why

| Complaint | Source | Why it does not apply |
|---|---|---|
| Breaks under Deferred events | DS2#142 | KeepBlox connects to no engine signal except BindToClose; its own signals call listeners directly. |
| MemoryStore throttling closes sessions | Suphi p7 #134, p11 #209 | KeepBlox's lock lives in the DataStore record; it uses no MemoryStore. |
| SubscribeAsync hangs in Team Test | PStore p5 #93 | the hand-over subscription never holds up a load (`Upkeep.listen`). |
| Lock scope differs between Studio and live | Suphi p7 #128 | the lock is part of the record; Studio without API access never touches a live key. |

## Still open

- Cost against crash loss is one trade-off no library escapes: data store writes an hour times the
  seconds a crash can lose is about constant (`bench/Frontier.luau`). KeepBlox writes every 300 s by
  default, as cheap as ProfileStore and Lapis, and loses less than ProfileStore on a crash (Lapis locks
  the player out instead). ProfileService loses less by writing every 30 s, at nine times the cost;
  `config = { renew = 30, death = 65 }` does the same with KeepBlox.
