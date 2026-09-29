# KeepBlox

Player data for Roblox that loses nothing, fails loudly, and never stutters a frame.

KeepBlox keeps session-locked player profiles on DataStore. It reads and writes the same records as
ProfileStore and speaks its lock protocol, so a game can switch by changing one `require`, run old and
new servers side by side during the rollout, and switch back.

> **Status: pre-alpha.** The core works and is proven in the simulator against the ProfileStore
> baseline (`tests/reference/BASELINE.md`). It has not run on live servers yet; do not ship it.

## What it promises

Each promise is an invariant the simulation harness checks after every step, across many virtual
servers and random fault schedules:

- An acknowledged save is never lost, and only one server can write a profile at a time.
- A failed load never writes; data that is not a profile is quarantined, never overwritten.
- A server that loses the session freezes its copy at once, so trades and purchases stop on stale data.
- Invalid data (NaN, bad UTF-8, cycles, near 4 MB) is refused before the write, with the path to the
  bad value.
- Offline messages are consumed exactly once; purchases are granted once and never lost.
- Shutdown releases every profile within the deadline; no call retries forever.
- Saving is spread across frames and respects the DataStore request budget.

## Development

```sh
rokit install          # the pinned toolchain
lefthook install       # the gates, before every commit
sh scripts/run-tests.sh
```

Tests run on [LuneBlox](https://github.com/XopoIII/LuneBlox), which runs the Luau version and fast flags
Roblox runs.

## License

MIT. See [LICENSE](LICENSE).
