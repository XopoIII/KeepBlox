# Changelog

Every release is listed here, newest first. The format follows Keep a Changelog, and versions follow
semantic versioning.

## Unreleased

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
