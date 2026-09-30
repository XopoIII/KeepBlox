# Live check

The same guarantees the simulator proves, run on Roblox's real DataStore, MessagingService and
MemoryStore from a Studio play server. Several virtual servers share the one real server: each is
`RobloxServices.build()` with its own jobId, and `crash()` freezes one where it stands.

**Only in the test experience** named in `roblox.env.example` (GP_TEST, which nobody plays). Data store
limits are shared by a whole experience (300 + 40 x players reads a minute), so a load test in a live
game throttles its players' saves. `Env.init` refuses to run anywhere else.

## Running it

1. In GP_TEST: Game Settings > Security > "Enable Studio Access to API Services", and HTTP requests
   allowed (Studio fetches the check from your machine).
2. `luneblox run tests/live/Serve` serves `src`, `tests/live` and the vendored ProfileStore on
   `http://127.0.0.1:34871/bundle.json`, read from disk on every request.
3. In Edit mode, run `Load.luau` in the command bar (or through Studio MCP): it builds
   `ServerStorage.KB_LiveCheck`.
4. Start Play, and run `Start.luau` on the server with `WHICH` set to `"functional"` (about 5 minutes)
   or `"stress"` (about 15). Progress is in `ServerStorage.KB_LiveCheck.Log.Value`; the last line
   starts with `DONE`.
5. Clean up: `Cleanup.run(print, { perMinute = 300 })` from Edit mode in the test experience (974 keys
   took 4 minutes). In a live game keep `perMinute` at 20: the experience's limit is shared with the
   players' saves. A removed key stops counting toward storage at once; Roblox keeps its old versions
   30 days, outside the limit.
6. Stop Play and delete `ServerStorage.KB_LiveCheck` before the place is saved or published.

## What it checks

| File | Checks |
|---|---|
| `Scenarios.luau` | round trip, hand-over from a live owner, a race of three, a crash takeover, shutdown |
| `Features.luau` | messages, receipts, versions and restore, releases that roll back, trades, compression, mixed ProfileStore servers |
| `Conformance.luau` | what the fakes model because it was measured: encoding of odd tables and numbers, version ids and tombstones, message limits, ordered ties. A failure means Roblox changed; fix the fake first |
| `Stress.luau` | 300 profiles on one player's budget, moves, crashes: never two owners, no loss, every load answers within its deadline |
| `Cleanup.luau` | removes everything a check left: every live key of every `KB_LiveCheck_*` data store (8 at once, paced by `perMinute` and the server's budget), the runs' ordered stores, and the virtual servers' MemoryStore entries; then lists again and reports what is left, which must be 0. Runs in Edit mode too |

## Results, 2026-09-30

Functional: 113 of 113. Hand-over from a live owner 4.2-4.6 s (simulator 3.2 s), crash takeover
11.6-12.9 s with at most one step of 0.5 s lost (simulator 9.1 s), shutdown of 5 profiles 1.35 s. Live
calls take 0.3-0.6 s each; that is the difference from the simulator.

Stress: see the CHANGELOG. It found that a load could run past `loadTimeout` and that loads polling a
spent budget starved hand-over saves; both are fixed and proven in `tests/unit/Overload.luau`.
