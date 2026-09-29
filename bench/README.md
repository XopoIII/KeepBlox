# Benchmarks

`sh scripts/run-bench.sh` (or `luneblox run bench/Run`) measures what saving a profile costs a frame.
It fails when a result is over its budget. It runs in pre-push and in CI.

A write first copies the profile in one go. It then checks and encodes the copy, and lets a frame pass
after every 2 ms of CPU. The longest stretch any single frame pays is therefore the copy plus one
slice, whatever the profile's size. That stretch is what the budget limits.

Measured on an Apple M1, LuneBlox 0.10.11:

| Profile | Size | Copy | Longest slice | Longest stretch | Budget (CI) | Total CPU |
|---|---|---|---|---|---|---|
| 10 KB | 8,090 B | 0.05 ms | 0.34 ms | 0.39 ms | 1.5 ms | 0.39 ms |
| 100 KB | 82,151 B | 0.56 ms | 2.05 ms | 2.61 ms | 6 ms | 3.97 ms |
| 1 MB | 841,594 B | 5.8 ms | 3.3 ms | 9.1 ms | 16 ms | 41 ms |

The budgets leave room for slower CI machines. The copy is the one part that cannot be split: until it
is done, the game could change the data mid-snapshot.
