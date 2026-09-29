# Baseline: ProfileStore in the simulator

The numbers KeepBlox has to beat. They were made with `luneblox run tests/Baseline 50 ProfileStore` on
LuneBlox 0.10.11. Re-run that command to refresh them.

Every scenario (`tests/sim/Scenarios.luau`) runs the unmodified ProfileStore v1.0.3 on simulated
servers over a shared fake data store and message bus. Each seed gives a different interleaving,
latency and timing, and a seed replays exactly. A simulated player plays one step a second, so
"progress lost" is in seconds of play. The ledger (`tests/sim/Ledger.luau`) checks the invariants on
every committed write, and at every session open.

## ProfileStore, seeds 1-50, worst case per scenario

| Scenario | Progress lost (steps) | Stale owner (s) | Slowest open (s) | Failed opens | Shutdown (s) | Violations |
|---|---|---|---|---|---|---|
| rejoin | 0 | 0.0 | 5.4 | 0 of 100 | - | none |
| handoff | 0 | 0.0 | 5.5 | 0 of 100 | - | none |
| crash | 287 | 0.0 | 46.6 | 0 of 100 | - | none |
| partitioned | 163 | 244.5 | 46.7 | 0 of 100 | - | none |
| thirdRequester | 0 | 0.0 | 5.4 | 50 of 150 | - | none |
| shutdown | 0 | 0.0 | 0.2 | 0 of 2500 | 3.1 | none |
| outage | 0 | 0.0 | 0.2 | 0 of 150 | - | none |
| poison | 259 | 0.0 | 46.5 | 0 of 100 | - | none |
| soup | 257 | 0.0 | 46.6 | 270 of 3147 | - | none |

**What it gets right:**
- No acknowledged save is lost.
- Only the lock holder ever changes `Data`.
- The load count never goes back.
- It survives a clean hand-off, a two-minute outage, and shutdown with 50 players on a slow data store.

**Where it falls short:** these are the weak spots in `.claude/plan/01-findings.md`, now measured.

| Weak spot | Scenario | What happens |
|---|---|---|
| A crash loses everything since the last autosave | `crash`, `soup` | Autosave runs every 300 s, so a crash loses up to 287 s of play |
| A dead owner is taken over slowly | `crash` | The next server gets the profile only after a force-load request, a 5 s wait and 40 s of retries: about 46 s |
| A stale owner stays active | `partitioned` | An owner that never gets the MessagingService request keeps the profile active, with stale data, for up to 244 s beside the new owner. Game code on that server can still trade or grant from it |
| One bad string blocks all saving | `poison` | Every later save fails with error 104, including the release, and nothing reports it. 259 s of play is lost, and the next server waits 46 s |
| The older of two waiting requesters loses | `thirdRequester` | By design, the older one gets nil. The game must kick that player |

## For contrast: a naive save module, seeds 1-20

`tests/sim/NaiveAdapter.luau` reads with GetAsync and saves with SetAsync every 30 s without honouring
another server's lock, much like a hand-rolled save module. It is here to prove that the ledger catches
what it claims to.

| Scenario | Progress lost (steps) | Stale owner (s) | Violations |
|---|---|---|---|
| rejoin | 21 | 0.2 | ack-lost x4, foreign-write x8, load-count-backwards x4 |
| handoff | 28 | 10.4 | ack-lost x20, foreign-write x40, load-count-backwards x20 |
| partitioned | 28 | 900.4 | ack-lost x20, foreign-write x1210, load-count-backwards x612 |
| thirdRequester | 30 | 300.5 | ack-lost x20, foreign-write x613, load-count-backwards x215 |
| soup | 29 | 0.0 | ack-lost x17 |

Even an ordinary rejoin within 5 s loses acknowledged progress. The new server reads before the old
server's final save lands, which is the fast-rejoin problem the plan found in gg's `Save.luau`.

## What KeepBlox must show

- **Zero violations in every scenario**, for many more seeds than the baseline uses.
- **Crash:** at most the dirty-autosave interval of progress lost (target 60 s).
- **Crash:** a dead owner taken over faster than 46 s.
- **Partitioned:** a stale owner frozen within the lease period, not after minutes.
- **Poison:** the bad value refused before the write, with its path. Earlier data keeps saving, and the
  release is never blocked.

## KeepBlox, seeds 1-50, worst case per scenario

Made with `luneblox run tests/Baseline 50 KeepBlox` (M2, default settings: renew 15 s, death 35 s).

| Scenario | Progress lost (steps) | Stale owner (s) | Slowest open (s) | Failed opens | Shutdown (s) | Violations |
|---|---|---|---|---|---|---|
| rejoin | 0 | 0.0 | 1.3 | 0 of 100 | - | none |
| handoff | 0 | 0.0 | 3.6 | 0 of 100 | - | none |
| crash | 15 | 0.0 | 39.1 | 0 of 100 | - | none |
| partitioned | 0 | 0.0 | 18.0 | 0 of 100 | - | none |
| thirdRequester | 0 | 0.0 | 7.9 | 0 of 150 | - | none |
| shutdown | 0 | 0.0 | 0.2 | 0 of 2500 | 3.1 | none |
| outage | 0 | 0.0 | 0.2 | 0 of 150 | - | none |
| poison | 214 | 0.0 | 0.2 | 0 of 100 | - | none |
| soup | 15 | 0.0 | 39.1 | 215 of 3150 | - | none |

| Weak spot | ProfileStore | KeepBlox |
|---|---|---|
| Play lost to a crash | up to 287 s | up to 15 s, one renewal |
| Dead owner taken over | about 46 s | about 39 s: the lease is watched for 35 s |
| Owner cut off from messaging | stale beside the new owner for up to 244 s | never stale; it hands over at its next renewal, within about 18 s |
| One bad string | blocks every save and the release; the next server waits 46 s | refused with its path, the lease still renews, and the release goes through at once |

In `poison`, the play after the bad string is still lost, because that data cannot be stored at all.
What changes is that the game is told the path of the bad value when it happens, the last good save
stays, and nothing else is held up.
