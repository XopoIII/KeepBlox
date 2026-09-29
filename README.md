# KeepBlox

Player data for Roblox that loses nothing, fails loudly, and never stutters a frame.

KeepBlox keeps session-locked player profiles on DataStore. It reads and writes the same records as
ProfileStore and speaks its lock protocol, so a game can switch by changing one `require`, run old and
new servers side by side during the rollout, and switch back.

**Documentation: [xopoiii.github.io/KeepBlox](https://xopoiii.github.io/KeepBlox/)**

> **Status: 0.1.0, the first release.** Everything below is proven in the simulator, against ProfileStore
> and five other libraries. It has not yet run in a live game: try it in a test place first.

## Against the libraries games use today

Every library runs unmodified in the same simulator: the same fakes of DataStore, MemoryStore,
MessagingService and the engine, the same players, faults and seeds (worst case over 20 seeds).

| Library | Violations | A crash loses (steps of play) | Slowest open (s) | Failed opens | Requests per player-hour |
|---|---|---|---|---|---|
| **KeepBlox** | **0** | **4** | 10.1 | **0** | 13.1 + 13.1 |
| ProfileStore | 0 | 287 | 46.6 | 20 | 13.6 + 13.6 |
| ProfileService | 0 | 29 | 65.8 | 27 | 122 + 122 |
| DocumentService | 0 | 0 (player locked out: 20 of 40 rejoins) | 15.9 | 389 | 25.9 + 25.9 |
| Lapis | 0 | 0 (player locked out: 20 of 40 rejoins) | 11.9 | 374 | 14 + 14 |
| DataStore2 | 61 | 287 | 0.6 | 0 | 0 + 1 |
| Suphi's DataStore Module | 1 | 0 (player locked out: 20 of 40 rejoins) | 0.5 | 355 | 1 + 120 |

Requests are data store reads + writes. KeepBlox also spends 45 MemoryStore units per player-hour on its
server heartbeat, which is how a dead server is known within seconds and how a crash loses only one
beat of play. The full tables, every scenario and the methodology are in
[bench/Benchmarks.md](bench/Benchmarks.md); `luneblox run bench/Report 20` makes them.

## What it promises

Each promise is a spec, and the simulation checks the data invariants after every write, across many
virtual servers and random fault schedules:

- An acknowledged save is never lost, and only one server can write a profile at a time.
- A crash loses about one 4 s heartbeat of play: each beat carries a snapshot the next server takes.
- A failed load never writes; data that is not a profile is quarantined, never overwritten.
- A server that loses the session freezes its copy at once, so trades and purchases stop on stale data.
- Invalid data (NaN, bad UTF-8, cycles, over 4 MB) is refused before the write, with the path to the bad
  value; the last good snapshot is stored instead.
- Offline messages are consumed exactly once; purchases are granted once and never lost.
- Shutdown releases every profile within the deadline; no call retries forever.
- Saving is spread across frames and respects the DataStore request budget.

## What it gives you

- Offline and admin edits that never kick a player (`store:edit`), and offline messages (`store:message`).
- Trades between two profiles that land in both or in neither (`store:trade`).
- Shared documents for guilds and clans, updated atomically from any server (`KeepBlox.shared`).
- Leaderboards mirrored to ordered data stores (`leaderboards`).
- A schema with numbered, testable migrations; deep defaults for template stores.
- Purchases through `KeepBlox.processReceipt`, version history with a safe restore, optional
  compression for large profiles, and Studio modes that never touch live data.
- Types for Luau (`--!strict` throughout) and roblox-ts (`types/index.d.ts`).

## Moving to KeepBlox

From ProfileStore or ProfileService, change one line; the keys and their format stay as they are:

```lua
local ProfileStore = require(path.to.KeepBlox.Compat.ProfileStore)
```

From DocumentService, Lapis, DataKeep, DataStore2 or Suphi's DataStore Module, point a store at the old
data: each key moves on its first load, and the old data is only read.

```lua
local store = KeepBlox.store("Profiles", {
	template = { coins = 0 },
	import = KeepBlox.importers.DocumentService({ store = "PlayerData" }),
})
```

## Development

```sh
rokit install          # the pinned toolchain
lefthook install       # the gates, before every commit
sh scripts/run-tests.sh
luneblox run bench/download && luneblox run bench/Report 20   # the benchmarks
npm ci --prefix docs && npm run build --prefix docs          # the documentation site
```

Tests run on [LuneBlox](https://github.com/XopoIII/LuneBlox), which runs the Luau version and fast flags
Roblox runs.

## License

MIT. See [LICENSE](LICENSE). Vendored reference code in `tests/reference/` keeps its own license.
