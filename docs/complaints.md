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
| 60-90 s wait for the lock after a server hop or auto-reconnect | PS#41, PS p60 #1274 | a live owner hands over on request in about a second; a dead one is taken after 35 s of an unmoved lease | `tests/scenario/KeepBlox.luau` (handoff, crash), `tests/reference/BASELINE.md` |
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
