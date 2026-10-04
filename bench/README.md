# Benchmarks

`sh scripts/run-bench.sh` (or `luneblox run bench/Run`) measures what saving a profile costs a frame.
It fails when a result is over its budget. It runs in pre-push and in CI.

A write first copies the profile in one go. It then checks and encodes the copy, and lets a frame pass
after every 2 ms of CPU. The longest stretch any single frame pays is therefore the copy plus one
slice, whatever the profile's size. That stretch is what the budget limits.

Measured on an Apple M1, LuneBlox 0.10.13:

| Profile | Size | Copy | Longest slice | Longest stretch | Budget (CI) | Total CPU |
|---|---|---|---|---|---|---|
| 10 KB | 8,090 B | 0.02 ms | 0.36 ms | 0.37 ms | 1.5 ms | 0.37 ms |
| 100 KB | 82,151 B | 0.17 ms | 2.07 ms | 2.24 ms | 6 ms | 3.75 ms |
| 1 MB | 841,594 B | 1.7 ms | 2.5 ms | 4.2 ms | 16 ms | 40 ms |

The budgets leave room for slower CI machines. The copy is the one part that cannot be split: until it
is done, the game could change the data mid-snapshot.

## Retries while the data store fails

`luneblox run bench/Retry` measures the gate on load retries (`src/Gate.luau`) in the simulator: each
scenario with every load retrying at its own backoff, and with the gate. Means over 10 seeds:

| Scenario | Retries | Load p50 | Load p99 | All loaded by | Requests |
|---|---|---|---|---|---|
| Store down 60 s, 10 servers on one player's budget, 300 joins | every load | 63.9 s | 76.1 s | 78.0 s | 1,533 |
| | gate | 56.0 s | 61.6 s | 64.0 s | 1,292 |
| Store down 60 s, 20 servers of 10 players, 200 joins | every load | 62.3 s | 62.5 s | 62.5 s | 3,399 |
| | gate | 60.9 s | 61.1 s | 61.1 s | 1,788 |
| Store down 90 s, 20 servers of 40 players, 800 joins | every load | 92.3 s | 92.5 s | 92.5 s | 17,623 |
| | gate | 91.0 s | 91.2 s | 91.3 s | 4,387 |
| Store down and up every 0.5 s for 30 s | every load | 23.6 s | 62.2 s | 64.7 s | 1,586 |
| | gate | 1.2 s | 56.5 s | 64.1 s | 982 |
| Store down and up every 3 s for 30 s | every load | 0.67 s | 3.23 s | 30.0 s | 615 |
| | gate | 0.62 s | 3.59 s | 30.0 s | 610 |
| 60 keys that never load among 400 loads that do | every load | 0.25 s | 2.85 s | 120.1 s | 3,658 |
| | gate | 0.26 s | 2.87 s | 120.1 s | 3,652 |

Without errors the gate never closes on a load: the overload of the live check (three servers on one
player's budget, a move every quarter second) and 800 players moving at once are the same with it.
The one cost found: when the store flickers every 3 s, the slowest loads wait up to a second longer
for their turn as the probe (p99 3.59 s against 3.23 s).

The overload scenario is not exactly repeatable: a save lets a frame pass every 2 ms of real CPU time,
so a busy machine moves its yields (683.1 loads against 682.5 between two runs of the same seeds).
