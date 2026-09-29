# Reference implementations

Third-party code the harness runs, unmodified, as a baseline and for conformance tests. It keeps its
own license and form, and it is excluded from our lint, format, strict-mode and size gates.

| File | Source | License |
|---|---|---|
| `ProfileStore.luau` | [MadStudioRoblox/ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) at commit `45c9847cbcf1fc260369c50eb335aba7c35aecdd` (2025-07-31, v1.0.3), byte for byte | Apache License 2.0; see [LICENSE](LICENSE) |
| `Suphi/` | Suphi's DataStore Module, Creator Store asset 11671168253, exported from Studio on 2026-09-29: the module (`init.luau`) and its children `Proxy`, `Signal`, `SynchronousTaskManager`, byte for byte (SHA-256 prefixes f52eeb7d6502, ebdf4a64d0e8, 0198a565b944, 81cad8ec0356) | its own permissive terms; see [Suphi/LICENSE](Suphi/LICENSE) |

Suphi's module has no repository or release to download from (the benchmarks download every other rival,
see `bench/download.luau`), so it is kept here. To update it, insert the asset in an empty place,
export the four scripts' `Source` unchanged, and record the date and hashes above.

ProfileStore runs on the simulated engine (`tests/sim/RobloxEnv.luau`). Each virtual server loads its
own copy, so module state is per server, as it is on Roblox.

To update it, replace the file with a newer upstream commit, record the commit here, and re-run the
suite. Never edit it by hand: a baseline we patched is no longer the baseline.
