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
  type -- but never on a property of a type a game reads (`Profile`, `Store`, `SharedStore`, ...). The
  old solver, which some games still check with, drops such a property entirely ("Key not found").
  `read` on an indexer of a parameter (`{ read [number]: Migration }`) is fine and keeps it covariant.
  `tests/consumer/` holds a game's use of the API, checked under both solvers by `scripts/type-check.sh`.
- **Not in the language yet:** `if local` (RFC #238, open). Do not use it until Roblox ships it.

When a newer Luau ships on Roblox, LuneBlox is bumped to it first, then the tools. Every tool must parse
the syntax we use: a tool that cannot is bumped or reported upstream, and the syntax is never dropped
quietly.

## Architecture in one breath

- Every Roblox service is reached through one seam, `src/Services.luau`. Its types are narrow and ours,
  not Roblox classes, so the harness hands in fakes and the real adapter (`src/RobloxServices.luau`)
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

## Distribution

- **Packages:** Wally (`xopoiii/keepblox`, `wally.toml`) and pesde (`xopoiii/keepblox`, `pesde.toml`
  and `pesde.lock`). `scripts/check-package.sh` checks that both carry every file of `src/`.
- **Without a package manager:** `KeepBlox.rbxm`, built with `rojo build -o KeepBlox.rbxm` and attached
  to each GitHub Release.
- **Not shipped yet:** a Creator Store model, and an npm package for roblox-ts (`types/index.d.ts` is
  copied by hand until then).
- **A release** carries one version in `wally.toml`, `pesde.toml`, `pesde.lock`, `README.md`,
  `docs/src/content/docs/index.mdx` and `docs/src/content/docs/getting-started/installation.mdx`, and
  its entry in `CHANGELOG.md`. `scripts/check-version.sh` holds them to it (pre-push and CI).

## Releasing

The steps, in order, as they were done for 0.6.3. The version bump and the changelog entry are part of
the pull request, not of this list.

1. Merge the pull request with a merge commit (`gh pr merge <n> --merge`), then check out `main` and
   pull.
2. On the merged `main`, run `sh scripts/check-package.sh` and `sh scripts/run-tests.sh`. Both must
   pass there, not only on the branch.
3. Tag and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. The tag push drafts the release
   (`.github/workflows/release.yml`): the tag is checked against the tree's version, the model is
   built and attached, and the notes start from the changelog entry.
4. Fill in the draft's notes, in order: a summary line, the link to the documentation, the changelog
   entry's sections (already there), **Evidence** (the spec count, the gates that passed, anything
   checked live, and anything that was not), **Known, not fixed** when there is something, and
   **Install** (the Wally line, the pesde line, the `.rbxm`). Then publish the release.
5. Publish the packages: `wally publish`, then `pesde publish --yes`. A published version cannot be
   replaced, so both come after the tag and the release.
6. The documentation deploys by itself on the push to `main` (`.github/workflows/docs.yml`): check that
   the site shows the new version.

`tests/reference/BASELINE.md` and the benchmark tables name the version they were measured on. A release
that does not measure them again leaves them as they are.

## Commands

| Command | What it does |
|---|---|
| `rokit install` | Installs the pinned toolchain (`rokit.toml`) |
| `lefthook install` | Installs the git hooks |
| `sh scripts/run-tests.sh` | Runs the suite on LuneBlox (`tests/Run.luau`) |
| `luneblox run tests/Mutate --yes` | Mutation adequacy: every mutant must fail the suite (about 90 min; `-- Lock` for one file) |
| `sh scripts/type-check.sh` | `luau-lsp analyze` over `src`, `tests`, `bench` |
| `selene src tests bench` | Lint |
| `stylua --check src tests bench` | Format check (`stylua src tests bench` to fix) |
| `sh scripts/check-strict.sh` | `--!strict` gate |
| `sh scripts/check-file-size.sh` | 300-line gate |
| `sh scripts/check-english.sh` | English-only gate |
| `sh scripts/check-version.sh` | Every place a release names the version agrees with `wally.toml` |
| `lefthook run pre-commit --all-files` | Every pre-commit gate over the whole tree |
