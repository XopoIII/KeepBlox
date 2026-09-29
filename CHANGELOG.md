# Changelog

Every release is listed here, newest first. The format follows Keep a Changelog, and versions follow
semantic versioning.

## Unreleased

### Added

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
