# KeepBlox - working notes

KeepBlox is a player-data library for Roblox: session-locked profiles on DataStore, built to lose
nothing, fail loudly, and never stutter a frame. It keeps ProfileStore's on-disk format and lock
protocol, so a game can switch with one `require`, run mixed servers during a rollout, and switch back.

The detailed work plan (findings, guarantees, architecture, harness, milestones M0-M9) lives in
`.claude/plan/`, which is local and not part of the repository.

## Everything here is written in English

Code, comments, identifiers, docs, commit messages, PR bodies. `scripts/check-english.sh` enforces it on
every commit. Box-drawing characters and em dashes are allowed. Conversation with the owner may be in
another language; nothing in another language lands in the repository.

## The tree is at zero

- No lint warnings, no type errors, no formatting drift. A warning is a failure: one that is tolerated
  once stops being read.
- Every `.luau` file starts with `--!strict` on line 1 and never opts out (`scripts/check-strict.sh`).
- No Luau file is over 300 lines (`scripts/check-file-size.sh`). A file that reaches the cap is split
  into modules, not exempted.
- The same gates run in lefthook (pre-commit, pre-push) and in CI (`.github/workflows/checks.yaml`).
- Vendored third-party code in `tests/reference/` is the only exemption, and it keeps its license.

## Guarantees are proven, not argued

Every guarantee the library makes is checked by a test in the harness. A guarantee without a test is a
wish and does not ship. Tests are strict: exact values, negative cases, no vacuous passes. A new spec is
seen failing once (against a deliberately broken fake or module) before it is trusted.

## Dependencies

- **No runtime dependencies.** `src/` is plain Luau. BlinkBlox lends ideas (schema, validation, buffer
  codec), not code linked at runtime.
- **Latest stable versions only.** Every tool, package and CI action is pinned exactly to its latest
  stable release at the time it is added or bumped (check with `gh release view -R owner/repo`). Never a
  prerelease, and never a pin copied from a sibling repo without checking.
- **BlinkBlox and LuneBlox are ours** (XopoIII/BlinkBlox, XopoIII/LuneBlox). When KeepBlox needs
  something from them (runtime parity, typedefs, an API), the change is made there and flagged to the
  owner, not worked around here.

## Modern Luau: the version Roblox runs

We write for the Luau Roblox runs today (0.740, September 2026), which LuneBlox also runs, and we use
what it offers:
- **`const`** for every binding that is never reassigned, including requires, module tables and
  functions (`const function`). Use `local` only for a binding that really is reassigned.
- **The new type solver.** `scripts/type-check.sh` runs luau-lsp with `LuauSolverV2`, as Studio checks
  games.
- **`read` / `write` property modifiers** in types, where a field must not be written through that
  type.
- **Not in the language yet:** `if local` (RFC #238, open). Do not use it until Roblox ships it.

When a newer Luau ships on Roblox, LuneBlox is bumped to it first, then the tools. Every tool must parse
the syntax we use: a tool that cannot is bumped or reported upstream, and the syntax is never dropped
quietly.

## Architecture in one breath

- Every Roblox service is reached through one seam, `src/Services.luau`. Its types are narrow and ours,
  not Roblox classes, so the harness hands in fakes and the real adapter (`src/Services/Roblox.luau`)
  translates.
- Nothing touches `game` at require time.
- Tests run on LuneBlox, which runs the Luau version and fast flags Roblox runs.

## The harness

`tests/fakes/` holds the fakes that stand in for Roblox. `Scheduler` is virtual time: every service
call is a yield point, and the seed decides the interleaving, so a failing run replays exactly from its
seed. `Clock` gives each virtual server its own skew and drift. Every fake behaviour cites the Roblox
doc it copies; when a live check disagrees with a fake, the fake is fixed first.

`tests/sim/` holds the simulation.
- **`RobloxEnv`** gives each virtual server the engine globals, so unmodified Roblox code (the
  vendored ProfileStore in `tests/reference/`) runs there. Each server loads its own copy of the module.
- **`Simulation`** runs the servers, the players and the faults.
- **`Ledger`** checks the invariants on every committed write.
- **`Scenarios`** holds the named stories. `Scenarios.soak` runs one of them over many seeds.
- **Adapters** put a library behind one shape, so the same scenarios drive ProfileStore (the baseline,
  `tests/reference/BASELINE.md`) and KeepBlox.

Two rules:
- **No Lune async API inside a simulated thread.** Lune's `fs`, `net` and `task` yield to Lune's own
  scheduler, which then resumes the thread outside the simulation. Read files beforehand
  (`RobloxEnv.read`).
- **A clean run proves nothing about the checker.** `NaiveAdapter` is a deliberately unsafe library,
  and the ledger's specs must catch its breaches.

## Live checks

Live checks and load tests run only in the test experience named in `roblox.env.example` (GP_TEST),
never in a live game: data store limits are shared by the whole experience, so load there throttles real
players. Test data goes in stores named `KB_LiveCheck_*`, and is removed afterwards.

## Distribution (proposed, settled at M6)

- **Packages:** pesde and Wally.
- **Without a package manager:** a `.rbxm` ModuleScript attached to GitHub Releases, plus a Creator Store
  model.
- **Studio plugin:** not a distribution channel, since this is a runtime library. It may come after
  0.1.0 as a support tool (a profile viewer and editor by key, version rollback) built on `Versions`.

## Commands

| Command | What it does |
|---|---|
| `rokit install` | Installs the pinned toolchain (`rokit.toml`) |
| `lefthook install` | Installs the git hooks |
| `sh scripts/run-tests.sh` | Runs the suite on LuneBlox (`tests/Run.luau`) |
| `luneblox run tests/Mutate --yes` | Mutation adequacy: every mutant must fail the suite (about 16 min; `-- Lock` for one file) |
| `sh scripts/type-check.sh` | `luau-lsp analyze` over `src`, `tests`, `bench` |
| `selene src tests bench` | Lint |
| `stylua --check src tests bench` | Format check (`stylua src tests bench` to fix) |
| `sh scripts/check-strict.sh` | `--!strict` gate |
| `sh scripts/check-file-size.sh` | 300-line gate |
| `sh scripts/check-english.sh` | English-only gate |
| `lefthook run pre-commit --all-files` | Every pre-commit gate over the whole tree |
