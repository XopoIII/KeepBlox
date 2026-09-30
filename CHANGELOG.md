# Changelog

Every release is listed here, newest first. The format follows Keep a Changelog, and versions follow
semantic versioning.

## Unreleased

## 0.4.1 - 2026-09-30

### Fixed

- A game checked with Luau's old type solver sees the whole public API. The properties of `Profile`
  (`key`, `loadCount`, `createdAt`, `onSaving`, `onSaved`, `onEnded`), `Store` (`name`, `onError`) and
  `SharedStore` (`name`) were written with the `read` modifier, which the old solver drops: using them
  failed with "Key not found". Found integrating KeepBlox into a game still on the old solver.

### Added

- `KeepBlox.Migration`, the type of one migration. On the old solver, annotate a list that mixes steps
  and `{ up, down }` pairs with it (`{ KeepBlox.Migration }`): that solver takes a list literal's element
  type from its first element.
- `tests/consumer/`: a game's use of the public API, type-checked under both solvers, and misuse that must
  fail on exactly the marked lines under each (`scripts/type-check.sh`, in CI and before a commit).

## 0.4.0 - 2026-09-30

### Fixed

- A heartbeat snapshot fires `onSaving` first, as every save does. A game whose play lives outside
  `Data` and writes it in `onSaving` had heartbeats carrying the data as last written, which matched
  the stored copy, so a crash lost the play since the last renewal (up to `renew`, 300 s) instead of
  about one beat. Found integrating KeepBlox into a game.

### Changed

- `onSaving` fires every `heartbeat` seconds (4 by default) for each profile a heartbeat snapshot
  covers, not only before data store writes. Keep its listeners cheap.

## 0.3.1 - 2026-09-30

### Fixed

- The pesde package holds the whole library. pesde reads `includes` as globs, so `"src"` matched the
  folder and nothing in it: the 0.1.0-0.3.0 pesde packages held only `src/init.luau`, and a game that
  installed one failed at its first `require`. The Wally packages were whole.

### Added

- `scripts/check-package.sh`, in CI and before a push: each tracked file under `src/` must be in the
  pesde archive (`pesde publish --dry-run`) and in Wally's file list.

## 0.3.0 - 2026-09-30

The first live check, in Studio against real DataStore, MessagingService and MemoryStore (2026-09-30),
in a private test experience: 113 of 113 checks. Loads, hand-overs, a three-server race, crash
takeovers, shutdown, messages (each handled once), receipts, versions and restore, migrations with
`writeVersion` rollback, trades, zstd compression and mixed ProfileStore servers both ways all held.
Measured live: hand-over from a live owner 4.2-4.6 s (simulator 3.2 s), crash takeover 11.6-12.9 s
(simulator 9.1 s) with at most one beat of play lost, shutdown of 5 profiles 1.35 s. Live calls take
0.3-0.6 s each; that is the difference.

A live load test (300 profiles on one player's budget, 10 virtual servers, a player moving every second,
two crashes) saw no double owner: hand-overs carried the data exactly, a crash lost at most one step,
and what was stored was each key's last owner's. Load tests must run in a separate, empty experience:
one run from a live game's Studio throttled that game, because data store limits are shared by the
whole experience.

### Fixed

- A load answers within `loadTimeout` in all, as documented. Each of its steps counted the timeout
  afresh: a player back on a server still releasing them, then waiting on another owner, could wait
  twice as long, and one load in the live stress test ran past 300 s.
- Under overload, saves get the budget first. Loads polled a spent data store budget, so the owners'
  final saves were throttled and hand-overs stalled (a metastable loop, seen live with 300 profiles on
  one player's budget). A load now waits for the server's budget, and its later tries leave a reserve to
  saves. In the overload spec, 683-692 loads land instead of 383-396, and none runs past its deadline.
- A shutdown whose releases cannot land (a spent budget, a failing data store) no longer loses the play
  since the last beat. Three seconds before the deadline, the data of every release still pending goes
  into one last MemoryStore beat (profiles up to 24 KB), and the next server stores it first.
- `restore` of a version that no longer exists, or of an id that is not one, answers `"noVersion"`.
  Before, a version overwritten later in its hour answered `"notAProfile"`, and a mistyped id threw out
  of `restore`. `readVersion` answers nil for both.

### Added

- `tests/live`: the live check, rerunnable from the repository. `luneblox run tests/live/Serve` serves it
  to Studio, `Load.luau` builds it, `Start.luau` runs the functional check (113 checks) or the load test.
  It runs only in the test experience named in `roblox.env.example`, and `Cleanup.luau` removes its data.
- The benchmarks compare a game with no library too: GetAsync on join, SetAsync on leave and every
  60 s, as the Roblox guides teach. Over 20 seeds it breaks 63 acknowledged saves, a crash loses 51
  steps of play, and a stale server keeps writing for 900 s.

### Changed

- Benchmarks re-measured on the live budget model. KeepBlox's figures are unchanged; DataStore2's slowest
  open is 8.8 s (it was 0.6 s under the old one-minute budget); a 1 MB save's longest frame is 4.1 ms.
- The test fakes follow what the live check measured, and every spec that depended on the old guesses
  was seen failing first:
  - a data store keeps NaN and infinities; it keeps a table with `[1]` as its array part and drops
    every other key without an error; it turns number keys of a dictionary into integer text;
  - a remove adds its tombstone as a version of its own; a version id that is not well formed is error
    25, and a well-formed one the key does not have reads nil;
  - a string message may have 1024 bytes and any other message 940 bytes of JSON; `Sent` has
    milliseconds;
  - ordered ties come in a fixed order that is not by key;
  - a new server starts with a burst (600 reads and writes with one player) and its budget is not
    capped; the experience-level limits (300 + 40 per user reads and 300 + 20 per user writes a
    minute) are shared by every server, and a request over them fails as it does live
    (`StandardReadExperienceThrottled`).
- The differential fuzzing of the save check now asks for more: Validate accepts exactly what the store
  keeps without loss. The two departures by choice: NaN and infinities, which the store keeps, are left
  out; and an array with holes is refused even when the store would keep it, since whether it does
  depends on how the table was built.

## 0.2.0 - 2026-09-30

### Fixed

- A hand-over request left in a server's MemoryStore entry no longer ends a later session of the same
  key. A player hopping from A to B and back to A within one beat lost their new session on A. Requests
  now name the owner's load count.
- A load that gave up (cancelled, closing, timeout) after a claim whose answer was lost no longer
  leaves its live server holding the key. Before, no other server could load the player while that
  server lived.
- `restore` brings back the restored version's schema version, so the migrations since then run on
  it. Before, a renamed field came back as its default.
- A live owner whose MemoryStore beats hang is no longer taken for dead by a quiet edit or a newcomer.
  The owner withdraws its beat from its records first, and a takeover on the beat's word lands only
  while the record still vouches for it.
- The size estimate counts an empty table as 2 bytes, not 1.
- A trade right after a migrating load stores the schema version with the migrated data. Before, the
  record kept the old version, and the next load ran the migrations again on migrated data.
- Data that contains itself no longer breaks every save: the copy a save takes recursed forever on a
  cycle, before the check could refuse it.

### Changed

- One bad value no longer costs the play around it. A value a data store cannot hold (a string that is
  not UTF-8, NaN, a function, a cycle) is repaired in what is stored, and each repair is reported once
  with its path. Before, every save of the session was refused until the game removed the value. Only
  a table's shape and the size limit still refuse the write. In the `poison` benchmark this loses 0
  steps, where it lost 204.
- Faster hand-overs: while a live owner hands over, the key is tried every half second. A dead owner's
  beat is looked at again the moment it could be judged dead. Slowest open in the benchmark: hand-over
  4.5 s to 3.2 s, three servers at once 8.2 s to 4.4 s, after a crash 10.0 s to 9.1 s.
- `restore` returns `purchasesSince`, the purchases granted after the restored version. The restored
  data no longer holds them and they stay granted, so the game must make them good; before, they were
  lost silently. The record notes the restore in `MetaData.KeepBlox.restored`.
- The snapshot a save takes is copied about 3x faster (one engine clone per table): the one step of a
  save that cannot be spread over frames. The check's text is also joined a chunk at a time inside the
  sliced walk, not all at once at its end. A 1 MB profile's longest frame stretch fell from 9.1 ms to
  4.3 ms.

### Added

- `tests/Mutate.luau`: mutation adequacy of the suite. 37 mutants, each a slip in code that keeps a
  guarantee, must each fail the suite.
- Differential fuzzing of the save check against the store's encoding.
- Releases you can roll back. A migration may be `{ up, down }`, and a store's `writeVersion` stores
  data at an older version: saves, trades, new profiles and MemoryStore snapshots alike. The release
  before it then reads everything, so a rollback locks no player out. `KeepBlox.migrateDown` tests the
  down steps on fixtures.
- The Wally and pesde packages, `xopoiii/keepblox` (0.1.0 is published on both).

## 0.1.0 - 2026-09-29

### Added

- Repository scaffolding:
  - the pinned toolchain;
  - the lefthook and CI gates (strict mode, 300-line cap, English only, selene, StyLua, luau-lsp);
  - the test runner on LuneBlox.
- `Services`, the seam through which the library reaches every Roblox service.
- Test harness fakes:
  - a seeded virtual scheduler;
  - per-server clocks with skew and drift;
  - DataStore and MessagingService fakes.
- The simulation harness:
  - an engine environment that runs unmodified Roblox modules on virtual servers;
  - a ledger that checks the data invariants on every committed write;
  - nine named scenarios, run over many seeds.
- The vendored ProfileStore v1.0.3 as the baseline, with its measured weak spots in
  `tests/reference/BASELINE.md`.
- The core library (`src/`):
  - session locking in ProfileStore's format, with a lease-based takeover of dead owners;
  - validation with the path of the bad value;
  - a freeze of a session's data when the session is lost;
  - load failures as typed results;
  - parallel release on shutdown;
  - an in-memory mode for Studio and scratch play tests.
- Benchmarks with budgets for the frame cost of saving (`bench/`).
- ProfileStore compatibility:
  - mixed ProfileStore and KeepBlox servers keep every invariant in the harness (`tests/sim/Mixed.luau`);
  - `Compat/ProfileStore` offers ProfileStore's API, so the migration is one `require`.
- Offline messages (`store:message`, `profile:onMessage`), handled exactly once; a full queue refuses instead
  of dropping.
- Purchases (`KeepBlox.processReceipt`): granted once, and reported granted only once stored.
- Versions: `store:versions`, `store:readVersion`, and `store:restore`, which refuses while a key is in use.
- A schema for the data (`KeepBlox.schema`): types, defaults, bounds and nesting, with path errors on
  refused saves.
- Numbered migrations with a stored schema version. A load refuses data from a newer version, a failing
  migration, or data that does not fit the schema; it lets the key go and writes nothing.
  `KeepBlox.migrate` tests a migration against fixtures.
- A server heartbeat in MemoryStore: a dead server's keys are taken within about 10 s, a live owner
  hears a hand-over request without MessagingService, and each beat carries snapshots of changed
  profiles, so a crash loses about one 4 s beat of play. Profiles too large for a snapshot are written
  every 30 s (`renewFallback`); the data store is written every 300 s otherwise (`renew`).
- Offline and admin edits (`store:edit`, `LoadOptions.quiet`) that never kick a player.
- Trades (`store:trade`) that land in both profiles or in neither, whatever dies when.
- Shared documents (`KeepBlox.shared`) updated atomically from any server, with `watch`.
- Leaderboards (`leaderboards`, `store:leaderboard`) mirrored to ordered data stores.
- Importers (`KeepBlox.importers`) for DocumentService, Lapis, DataKeep, DataStore2 and Suphi's
  DataStore Module.
- Optional compression for large profiles (`compress`), Studio modes (`studio = "memory" | "copy"`),
  `store:close()` for tests, and roblox-ts declarations (`types/index.d.ts`).
- Benchmarks against ProfileStore, ProfileService, DocumentService, Lapis, DataStore2 and Suphi's
  DataStore Module (`bench/Report.luau`, `bench/Benchmarks.md`), and a documentation site (`docs/`).

### Fixed

- A new profile ran every migration on the template.
- A quick rejoin into the same server failed with "open" while this server was still releasing.
- A save loop queued one write per call; manual saves now join the one waiting.
