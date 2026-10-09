# Changelog

Every release is listed here, newest first. The format follows Keep a Changelog, and versions follow
semantic versioning.

## Unreleased

## 0.6.8 - 2026-10-10

A game may now cancel a thread that is inside `store:load` or `profile:release()`: both run in a thread
the library owns, and the caller only waits. Nothing about stored data, the lock payload, the keys,
the messages or the number of requests changed for a caller nobody cancels: 0.6.7 and 0.6.8 servers
run side by side, and each reads what the other stored.

### Fixed

- A thread cancelled inside **`store:load`** no longer leaves its key marked as opening
  ([#31](https://github.com/XopoIII/KeepBlox/issues/31)). Before, every later load of that key on
  that server answered `"open"` until the server ended, and a claim that had already landed left the
  key held with no session behind it. Now the load runs to its end without its caller. A session it
  opens, which nobody is left to hold, is released at once with a final save of everything the load
  read (a dead owner's last beat, a settled trade, migrated data), and the key comes free.
- A thread cancelled inside **`profile:release()`** no longer stops the retries of the final write
  (#31). Before, a write that failed after the cancel was not tried again until something else called
  the release, so the session stayed half ended and the key held. Now it is retried with the same
  backoff as when the caller waits, and the key comes free with nobody calling `release` again.
- A load that **throws** no longer leaves its key marked as opening either (a compressed profile on a
  server that cannot decompress, for one). The claim it had made is still not given back: see
  [#34](https://github.com/XopoIII/KeepBlox/issues/34).

### Changed

- A `store:load` of a key whose earlier load was cut short by a cancelled thread **waits** for that
  load to be undone, then claims the key afresh, as it already did for a release still in flight. The
  wait is the load's own: it ends on `cancel`, on shutdown and at `loadTimeout`. A second load of a
  key while the first is in flight with its caller still there gets `"open"` at once, as before.
- A cancelled thread does **not** make a load give up: it runs on as if its caller were there (up to
  `loadTimeout` when the key is held elsewhere), and what it opens is released. To stop a load early,
  pass `cancel`, as before.
- **Shutdown waits for a load in flight**, whoever started it, as well as for the open sessions,
  within the same `shutdownDeadline`. Such a load answers `"closing"` at its next look and gives back
  what it took; before, `store:close()` and the server's close could return while that give-back was
  still on its way. With no load in flight the close takes the time it took.
- A load or a release that throws after its caller was cancelled is reported through `store.onError`
  ("a load failed after its caller was cancelled: ...", "a release failed after ..."). With its caller
  still there the error reaches that caller exactly as before.
- Each load and each release costs one more thread: about 2.2 microseconds on LuneBlox for a call that
  parks once (1.39 to 3.55, best of seven, three runs), about 1.4 for one that returns at once. A whole
  load and release on the simulator read 496 and 493 microseconds before and after (medians of five
  alternated runs, two of them noisy; best runs 460 and 475). Either is one data store request at the
  least. `scripts/run-bench.sh` (the frame cost of a save) does not go through these paths and reads
  the same before and after.

### Added

- `src/Apart.luau` (a call run in a thread of its own, its caller only waiting) and `src/Settle.luau`
  (the wait before a key is loaded again, moved out of `Open.luau` and widened).
- Specs through the real paths (`tests/unit/CancelledLoad.luau`, `CancelledLoadPaths.luau`,
  `CancelledRelease.luau`, `Apart.luau`): the caller of a load cancelled at every step the world takes
  while the load runs, for a new key, a key handed over by a live server, a key taken from a dead one
  with newer play in its last beat, an imported key and a key with an unfinished trade; after each
  cancel the key is loaded again at once, or left alone for half a minute, or the server is shut down,
  and each time the key is not left held, the next load gets a session with exact coins and nothing
  is reported. The caller of a release cancelled at every step with its write failing once, and with
  its write lost in flight; the same backoff with a caller and without; a load and a release that
  throw, heard by the caller or by the store; shutdown with a cancelled load or release in flight; and
  loads and releases nobody cancels, whose answers, order and request counts are pinned. Thirteen
  mutants (`tests/MutantsApart.luau`).

### Known, not fixed

- A load that gives up through `cancel` or shutdown at the moment its **takeover** claim lands gives
  the key back without the dead owner's last beat
  ([#33](https://github.com/XopoIII/KeepBlox/issues/33)). Older than this release, and not reachable
  through a cancelled thread: that load runs on and stores the beat.
- A load whose claim had landed when shutdown began still answers with a profile, and the shutdown
  does not release it; a load that throws after its claim leaves the key held (#34). Both older than
  this release.

### Checked on Roblox, and not

- That a cancelled thread reads as dead was run in Roblox Studio (the test place, edit mode,
  2026-10-10): a thread parked in `coroutine.yield()` or in `task.wait` reads `"dead"` after
  `task.cancel`, and after `coroutine.close`; a caller seen from the thread it spawned reads
  `"normal"`. 0.6.7 had this from LuneBlox only. The fix rests on it in two places: to pass a dead
  caller over instead of waking it, and to know that the session a load opened has nobody to hold it.
- The library itself was not run in a Roblox server for this release: the specs run on LuneBlox.

## 0.6.7 - 2026-10-09

A game may now cancel a thread that is inside `profile:save()`: every write runs in a thread the
library owns, and the caller only waits for it. Nothing about stored data, the lock protocol, the
keys, the messages or the number of requests changed: 0.6.6 and 0.6.7 servers run side by side, and
each reads what the other stored.

### Fixed

- A thread cancelled while its write is **in flight** no longer takes the session's write lane with it
  ([#29](https://github.com/XopoIII/KeepBlox/issues/29)). Before, the lane stayed taken for good: every
  later save, every renewal and the release queued behind it in silence, and the key came free only
  when its lease was judged dead. Now the write ends as it would have (it lands, fails or times out),
  the lane passes on, and shutdown waits for it as for any other write.
- A thread cancelled while it owns a **queued** manual save no longer leaves later `profile:save()`
  calls waiting forever (#29). The shared save runs in its turn, the callers that joined it get their
  answer, and the next manual save gets a write of its own.
- `Studio.guard`'s one-time access check uses the same lane, so a cancelled first caller no longer
  leaves every later call of the store waiting on a check that never ends. (Proven by the lane's
  specs; the guard has no cancel spec of its own.)

### Changed

- A save or release whose caller was cancelled while it waited in the lane is now **written** in its
  turn. In 0.6.6 it was skipped. The request is the one the caller asked for, not an extra one; what is
  stored is the profile's data at that moment, as for any save.
- A write that throws after its caller was cancelled is reported through `store.onError`
  ("a write failed after its caller was cancelled: ..."). A write that throws with its caller still
  there reaches that caller exactly as before, and one that only fails (`save failed: ...`) is reported
  as before either way.
- Each write costs one more thread: about 1.1 microseconds on LuneBlox for a call that never yields
  (0.31 to 1.45), about 1.7 for one that parks once (1.72 to 3.43), medians of five alternated runs. A
  write is a data store request and about 370 microseconds of checking for a 10 KB profile, once every
  `renew` seconds a profile; `scripts/run-bench.sh` (the frame cost of a save) does not go through the lane and reads
  the same before and after.

### Added

- Specs through the real paths (`tests/unit/Cancelled.luau`, `CancelledErrors.luau`, and the lane's own
  in `tests/unit/Serial.luau`): a manual save cancelled in mid-write, and one cancelled while queued,
  each followed by a manual save, a renewal and a release that store exact values; a lost request
  whose caller was cancelled, ended by the call's deadline; shutdown with such a write in flight,
  which returns only after it and the final save have landed, in order; a write that fails and one
  that throws, heard by the caller, by those who joined and by the store; and callers nobody cancels,
  whose answers, order and request count are pinned. Eleven mutants (`tests/MutantsLane.luau`).

### Not checked on Roblox

- That `task.cancel` leaves a thread parked in `coroutine.yield()` dead (`coroutine.status` reads
  `"dead"`, and the thread never runs again) is measured on LuneBlox 0.10.13, which runs the same Luau,
  and is what Roblox documents for `task.cancel`. It was not run in a Roblox server. The fix does not
  rest on it for the lane: the write no longer runs in the cancelled thread at all. It rests on it
  only to pass a dead caller over instead of waking it.
- The cancel specs run in the simulator, not in `tests/live`.

### Not done

- Two other calls still do their work in the caller's own thread
  ([#31](https://github.com/XopoIII/KeepBlox/issues/31)). A thread cancelled inside `store:load` leaves
  the key marked as opening on that server, so later loads of it answer `"open"`. A thread cancelled
  inside `profile:release()` gets its final write in flight landed, but if that write fails nobody
  retries until the release is called again or the server shuts down. Do not cancel a thread that is
  inside `store:load` or `profile:release`.

## 0.6.6 - 2026-10-09

Fixes for a cancelled caller and a failed hand-over subscription, and one walk of the data less at
every beat. Nothing about stored data or the lock protocol changed: 0.6.5 and 0.6.6 servers run side
by side, and each reads what the other stored.

### Fixed

- A session's write lane no longer sticks when the game cancels a thread that was **queued** in it (a
  `task.cancel` on a thread whose `profile:save` was waiting for a write in flight to finish). The dead
  caller is skipped; before, every later save and the release queued behind it forever, silently. A
  caller that joined a manual save and was cancelled meanwhile is passed over too, so the others
  still get their answer.
- A hand-over subscription that fails is retried with a backoff (from 1 s, doubling up to 30 s) until
  the session ends. Before, the session lived on without its listener, and a hand-over surfaced only
  at the owner's next write: up to `renew` seconds late instead of about a second.
- `Signal.disconnect` now drops the listener: a long-lived signal (a store's `onError`) no longer
  keeps every connection ever made, and a fire copies only the listeners still connected. A second
  `disconnect` does nothing.

### Changed

- A heartbeat snapshot and the packing of a profile no longer walk the data a second time: the check
  before a write now reports itself whether the data holds a buffer, which compression cannot carry.
- The harness's `Scheduler.cancel` now closes the thread, as `task.cancel` does, so a cancelled
  thread reads as dead in the simulation too.
- The harness's clock fails the run when its `spawn` is handed a dead thread. LuneBlox's own
  `task.spawn` passes over one in silence; the harness takes the stricter reading.

### Added

- `scripts/check-version.sh`: every place a release names the version (both packages, the README, the
  documentation, the changelog) must agree with `wally.toml`. It runs in pre-push and in CI.
- Mutation adequacy runs weekly in CI (`.github/workflows/mutate.yml`), not only by hand.
- A pushed tag drafts the GitHub release (`.github/workflows/release.yml`): the tag is checked against
  the tree's version, the model is built and attached, and the notes start from the changelog entry.
- Specs for the signal (order, disconnect, a disconnect during a fire, destroy, and that a
  disconnected listener is let go) and for a cancelled caller that had joined a manual save, each
  with its mutant.

### Not done

- Only a cancelled caller that was queued is handled. A thread cancelled while it **holds** the lane
  (parked inside its write) still leaves the lane taken for good, and a cancelled thread that owned a
  queued manual save leaves later manual `profile:save` calls waiting forever (renewals and the release
  still land). Both were so in 0.6.5 and are tracked in
  [#29](https://github.com/XopoIII/KeepBlox/issues/29). Until then, do not cancel a thread that is
  inside `profile:save` or `profile:release`.

## 0.6.5 - 2026-10-05

One field for games that pay for the time a player was away. Nothing about stored data or the lock
protocol changed: 0.6.4 and 0.6.5 servers run side by side.

### Added

- `profile.lastSavedAt`: when the record was last written before this session took it, in Unix seconds.
  It is the `LastUpdate` the load found in the record, which is the earlier session's last save, and
  its release when that session ended cleanly. The load itself writes `LastUpdate`, so the stored
  record could no longer say; the claim now reads the value before it writes over it. It is 0 for a
  profile that had never been stored, for a record that holds no number there, and for data taken from
  another library, whose record is made by the load. It does not move while the session saves. A mock
  store reports it as a real one does, and `studio = "copy"` reports the live profile's. The roblox-ts
  declarations gain it too.

### Not done

- `lastSavedAt` is the time of the last write, whatever made it. A load that took the key and gave it
  back (cancelled, timed out while settling a trade, data no migration could read) wrote the record,
  and so did a claim whose answer was lost and which the same load then made again: the next value is
  that moment, not the last play. After a server died, it is the dead session's last stored save,
  though the load may recover newer play from its MemoryStore snapshot.
- The ProfileStore wrapper has no such field: ProfileStore's profile has none to map it to.

## 0.6.4 - 2026-10-05

What 0.6.3 left open in Studio, and typed profile data. Nothing about stored data or the lock protocol
changed: 0.6.3 and 0.6.4 servers run side by side, and a live server behaves as it did.

### Fixed

- A shared store opens in Studio in a place that cannot reach live data. `KeepBlox.shared` threw in a
  place file that was never published ("You must publish this place to the web to access DataStore."),
  and with API access off its calls failed. It now does what a store does since 0.6.3: in an
  unpublished place it opens in memory, and without API access its first `read`, `update` or `watch`
  makes one read-only call (`GetAsync` of `__KeepBlox_access_check`) and moves to memory when that is
  refused. Watchers hear the updates made in memory. On a live server the error is raised as before,
  and so is any other error in Studio.
- `studio = "copy"` no longer hides a live profile it could not read. The profile started from the
  template without a word, so a play test looked at a new player and took it for the real one. It still
  starts from the template, since a play test must not be blocked, and `store.onError` fires once for
  the key, with the key and "The live profile could not be read for the copy (the engine's error): this
  play test starts from the template".

### Added

- `SharedStore.onError`, a signal of `(key, message)` as a store's is. It reports that Studio keeps the
  documents in memory: once, with the key `""`, on the first call, with the same two messages a store
  uses. It reports nothing else yet: a failed `read` or `update` says why in its result. The roblox-ts
  declarations gain it too.
- Typed profile data. `KeepBlox.Store<T>`, `KeepBlox.Profile<T>` and `KeepBlox.LoadResult<T>` take the
  shape of the data, and `T` defaults to `any`, so every annotation written without it means what it
  did. A game names its shape once, `const store: KeepBlox.Store<PlayerData> = KeepBlox.store(...)`,
  and `profile.Data`, `profile.LastSavedData`, `onSaved`, `store:profiles()` and the data `store:edit`
  and `store:trade` hand over are `PlayerData` under both type solvers. The consumer type check holds
  a typed store beside the plain one, and two misuses of it that must fail.

### Changed

- With `studio = "copy"`, a key the play test already holds in memory is not read from the live store
  again. Memory won before as well; the read was wasted.
- In Studio, a shared store's first call makes one extra read, of the key `__KeepBlox_access_check`.
  Live servers do not make it.

### Not done

- `KeepBlox.store` does not work the data's type out from `template`: the shape is the annotation's.
  Inferring it would type every existing store by its template literal, where `items = {}` says nothing
  of what the game later puts in it, and code that type-checks today would stop. `SharedStore`,
  `ReceiptOptions`, `store:readVersion` and the results of `store:edit` stay untyped (`any`).
- The Studio fallbacks are proven against the fakes, with the engine's messages as 0.6.3 recorded them.
  The shared store's was not run in Studio for this release.

## 0.6.3 - 2026-10-05

Found while putting 0.6.2 into a live game. Nothing about stored data or the lock protocol changed: 0.6.2
and 0.6.3 servers run side by side.

### Fixed

- A store opens in Studio in a place file that was never published. `KeepBlox.store` threw there, with
  `studio = "live"` (the default) and with `"copy"`: Roblox refuses the data store itself ("You must
  publish this place to the web to access DataStore."), before the read-only access check could run.
  The store now opens in memory, and `store.onError` fires once on the first load, with the key `""`
  and "This place is not published: profiles are kept in memory, and nothing is saved". On a live
  server the error is raised as before, and so is any other error in Studio.
- `KeepBlox.processReceipt` is typed: it takes `ReceiptOptions` and returns
  `(receipt: Receipt) -> Enum.ProductPurchaseDecision`. It took and returned `any`, so a mistake in the
  options was found only when a purchase arrived.

### Added

- The module exports the types a game needs to annotate its own code: `StoreOptions`, `LoadOptions`,
  `LoadFailure`, `EndReason`, `ReceiptOptions`, `Receipt`, `ReceiptDecision`, `SharedOptions` and
  `ConfigOverrides`. Options built apart from the call no longer need a cast to `any`. The roblox-ts
  declarations gain `ReceiptDecision`, `SharedOptions`, `Config` and `ConfigOverrides`.
- The consumer type check (`tests/consumer/Game.luau`) holds the documented load, `if not result.ok
  then ... return end` followed by `result.profile`, under both solvers, with the result annotated and
  not.

### Changed

- A store's `config` option is typed by its settings (`ConfigOverrides`), not as `{ [string]: number }`.
  A misspelt setting is a type error under the new solver; the old solver cannot make that check, and
  the assert when the store opens stays for it. A table of settings held in a variable needs the
  annotation `KeepBlox.ConfigOverrides`: one typed `{ [string]: number }`, or under the new solver not
  typed at all, is no longer accepted. Nothing changes at run time.
- The README and the documentation say where the library runs: in one live public game (Grabby Pit)
  since early October 2026.

## 0.6.2 - 2026-10-04

The library's code is the same as in 0.6.1: `src/` did not change. A game on 0.6.1 gains nothing by
updating.

### Changed

- Every tool is on its latest stable release: LuneBlox 0.10.13, rojo 7.7.1, selene 0.32.0, lefthook
  2.1.16, Starlight 0.42.5. The suite (305 specs), the frame budgets and the ProfileStore baseline pass
  on them, and the published numbers are measured again on LuneBlox 0.10.13: a 1 MB save's longest
  frame is 4.2 ms (it was 4.1 ms, within noise).
- CI actions are pinned to exact tags, not to moving major tags.
- The type gate reads the Roblox API definitions of the luau-lsp release it is pinned to (1.70.1), not
  of whatever luau-lsp's `main` held on the day they were downloaded.

### Added

- The KeepBlox icon, on the documentation site and in the README.

## 0.6.1 - 2026-10-02

### Fixed

Both found by the live load test (GP_TEST, 2026-10-02) run on 0.6.0, and both older than it.

- A key being taken over from a crashed server could open twice on the server taking it over. The load
  reads the dead owner's snapshot from MemoryStore after its claim, and the key was no longer marked as
  opening by then, so a second `load` of the key meanwhile (a player rejoining) was not refused as
  `open`: it claimed the key again. The server then held two live sessions of one profile, the second
  with the stored data, and the first one's unsaved play was lost. The key now stays marked until its
  session is listed.
- The dead owner's snapshot is stored however often the data store refuses the write, until the load's
  deadline. It was tried once: on a spent budget that one write failed, the stored data was used, and
  the play since it was last stored was lost (two minutes, in the test) instead of about one beat.

## 0.6.0 - 2026-10-02

### Fixed

- A long list changed in a few places far apart keeps its crash snapshot. Past about 64 items between
  the first and the last change, the whole stretch was replaced in one edit: an inventory of 200 items
  with two taken out near its ends made 22 KB of edits, far over `snapshotBytes`, so a crash lost up to
  `renewFallback`. Such stretches are now searched by how many items differ (Myers' O(ND)), and the same
  change is 89 bytes. A stretch that differs in more than 32 places is still replaced whole.

### Changed

- While a server's data store calls fail, its loads no longer each retry at their own backoff: after
  its backoff a load waits its turn, one of them tries the store about once a second, and the first
  that is answered lets the rest go at once. Retries fired at a store that is down only fail, and they
  spent the budget the loads needed once it was back. In the simulator, after a minute's outage on
  servers with one player's budget, the last of 30 loads lands 4 s after the store is back, not 18 s;
  with a full budget, 1.1 s after, not 2.5 s; and an outage costs 16-75% fewer requests. A lone failing
  load, a key that fails among keys that work, and a server with no failing calls behave as before.
  When the store flickers every 3 s, the slowest loads take up to a second longer (p99 3.6 s, was 3.2).
  `bench/Retry.luau` measures it.
- The diff of a long list no longer builds a table of every pair it will not use: 700 items with two
  taken out take 0.6 ms, not 3.9 ms.
- A number that is not an integer encodes 6-18% faster; the text is unchanged.

## 0.5.0 - 2026-09-30

### Fixed

- A profile over `snapshotBytes` (1000 bytes) is covered by the heartbeat snapshots too, so a crash
  loses about one beat of it, not up to `renewFallback` (30 s). Its snapshot holds only its edits since
  it was last stored, with a fingerprint of that data; the server taking over applies them only to the
  record they were made against, and otherwise keeps the stored data. Lists are aligned, so a thing
  taken out of the middle of fifty is one edit. Measured on a game's profile shape (about 230 bytes of
  JSON per thing), the whole data passes 1000 bytes with the first few things and no compression brings
  fifty under the MemoryStore quota of about 1 KB per player; the edits between two writes do fit.

### Changed

- A hand-over to a live owner takes 2.9 s in the benchmark, not 3.2: a newcomer that looked at the
  owner's beat less than a second ago while waiting reuses that verdict right after trying the data
  store, instead of one more MemoryStore call before its next wait.
- Each beat walks every open profile stored under 128 KB (it used to stop at `4 * snapshotBytes`), over
  as many frames as it needs.
- A server entry in `KB_servers` gains `x`, the edit snapshots. KeepBlox before 0.5 does not read it,
  so during a rollout an older server taking over a large profile keeps the stored data, as before.

### Added

- `bench/Heartbeat.luau`: every story at `heartbeat` 4 and 2. At 2 s a crashed owner is taken over in
  5.0 s instead of 9.1, losing 2 steps instead of 4, with no violation, for 87 MemoryStore units a
  player-hour instead of 45.

## 0.4.1 - 2026-09-30

### Fixed

- A game checked with Luau's old type solver sees the whole public API. The properties of `Profile`
  (`key`, `loadCount`, `createdAt`, `onSaving`, `onSaved`, `onEnded`), `Store` (`name`, `onError`) and
  `SharedStore` (`name`) were written with the `read` modifier, which the old solver drops: using them
  failed with "Key not found". Found integrating KeepBlox into a game still on the old solver.

### Added

- `KeepBlox.Migration`, the type of one migration. On the old solver, annotate a list that mixes steps
  and `{ up, down }` pairs with it (`{ KeepBlox.Migration }`): that solver takes a list literal's element
  type from its first element.
- `tests/consumer/`: a game's use of the public API, type-checked under both solvers, and misuse that must
  fail on exactly the marked lines under each (`scripts/type-check.sh`, in CI and before a commit).

## 0.4.0 - 2026-09-30

### Fixed

- A heartbeat snapshot fires `onSaving` first, as every save does. A game whose play lives outside
  `Data` and writes it in `onSaving` had heartbeats carrying the data as last written, which matched
  the stored copy, so a crash lost the play since the last renewal (up to `renew`, 300 s) instead of
  about one beat. Found integrating KeepBlox into a game.

### Changed

- `onSaving` fires every `heartbeat` seconds (4 by default) for each profile a heartbeat snapshot
  covers, not only before data store writes. Keep its listeners cheap.

## 0.3.1 - 2026-09-30

### Fixed

- The pesde package holds the whole library. pesde reads `includes` as globs, so `"src"` matched the
  folder and nothing in it: the 0.1.0-0.3.0 pesde packages held only `src/init.luau`, and a game that
  installed one failed at its first `require`. The Wally packages were whole.

### Added

- `scripts/check-package.sh`, in CI and before a push: each tracked file under `src/` must be in the
  pesde archive (`pesde publish --dry-run`) and in Wally's file list.

## 0.3.0 - 2026-09-30

The first live check, in Studio against real DataStore, MessagingService and MemoryStore (2026-09-30),
in a private test experience: 113 of 113 checks. Loads, hand-overs, a three-server race, crash
takeovers, shutdown, messages (each handled once), receipts, versions and restore, migrations with
`writeVersion` rollback, trades, zstd compression and mixed ProfileStore servers both ways all held.
Measured live: hand-over from a live owner 4.2-4.6 s (simulator 3.2 s), crash takeover 11.6-12.9 s
(simulator 9.1 s) with at most one beat of play lost, shutdown of 5 profiles 1.35 s. Live calls take
0.3-0.6 s each; that is the difference.

A live load test (300 profiles on one player's budget, 10 virtual servers, a player moving every second,
two crashes) saw no double owner: hand-overs carried the data exactly, a crash lost at most one step,
and what was stored was each key's last owner's. Load tests must run in a separate, empty experience:
one run from a live game's Studio throttled that game, because data store limits are shared by the
whole experience.

### Fixed

- A load answers within `loadTimeout` in all, as documented. Each of its steps counted the timeout
  afresh: a player back on a server still releasing them, then waiting on another owner, could wait
  twice as long, and one load in the live stress test ran past 300 s.
- Under overload, saves get the budget first. Loads polled a spent data store budget, so the owners'
  final saves were throttled and hand-overs stalled (a metastable loop, seen live with 300 profiles on
  one player's budget). A load now waits for the server's budget, and its later tries leave a reserve to
  saves. In the overload spec, 683-692 loads land instead of 383-396, and none runs past its deadline.
- A shutdown whose releases cannot land (a spent budget, a failing data store) no longer loses the play
  since the last beat. Three seconds before the deadline, the data of every release still pending goes
  into one last MemoryStore beat (profiles up to 24 KB), and the next server stores it first.
- `restore` of a version that no longer exists, or of an id that is not one, answers `"noVersion"`.
  Before, a version overwritten later in its hour answered `"notAProfile"`, and a mistyped id threw out
  of `restore`. `readVersion` answers nil for both.

### Added

- `tests/live`: the live check, rerunnable from the repository. `luneblox run tests/live/Serve` serves it
  to Studio, `Load.luau` builds it, `Start.luau` runs the functional check (113 checks) or the load test.
  It runs only in the test experience named in `roblox.env.example`, and `Cleanup.luau` removes its data.
- The benchmarks compare a game with no library too: GetAsync on join, SetAsync on leave and every
  60 s, as the Roblox guides teach. Over 20 seeds it breaks 63 acknowledged saves, a crash loses 51
  steps of play, and a stale server keeps writing for 900 s.

### Changed

- Benchmarks re-measured on the live budget model. KeepBlox's figures are unchanged; DataStore2's slowest
  open is 8.8 s (it was 0.6 s under the old one-minute budget); a 1 MB save's longest frame is 4.1 ms.
- The test fakes follow what the live check measured, and every spec that depended on the old guesses
  was seen failing first:
  - a data store keeps NaN and infinities; it keeps a table with `[1]` as its array part and drops
    every other key without an error; it turns number keys of a dictionary into integer text;
  - a remove adds its tombstone as a version of its own; a version id that is not well formed is error
    25, and a well-formed one the key does not have reads nil;
  - a string message may have 1024 bytes and any other message 940 bytes of JSON; `Sent` has
    milliseconds;
  - ordered ties come in a fixed order that is not by key;
  - a new server starts with a burst (600 reads and writes with one player) and its budget is not
    capped; the experience-level limits (300 + 40 per user reads and 300 + 20 per user writes a
    minute) are shared by every server, and a request over them fails as it does live
    (`StandardReadExperienceThrottled`).
- The differential fuzzing of the save check now asks for more: Validate accepts exactly what the store
  keeps without loss. The two departures by choice: NaN and infinities, which the store keeps, are left
  out; and an array with holes is refused even when the store would keep it, since whether it does
  depends on how the table was built.

## 0.2.0 - 2026-09-30

### Fixed

- A hand-over request left in a server's MemoryStore entry no longer ends a later session of the same
  key. A player hopping from A to B and back to A within one beat lost their new session on A. Requests
  now name the owner's load count.
- A load that gave up (cancelled, closing, timeout) after a claim whose answer was lost no longer
  leaves its live server holding the key. Before, no other server could load the player while that
  server lived.
- `restore` brings back the restored version's schema version, so the migrations since then run on
  it. Before, a renamed field came back as its default.
- A live owner whose MemoryStore beats hang is no longer taken for dead by a quiet edit or a newcomer.
  The owner withdraws its beat from its records first, and a takeover on the beat's word lands only
  while the record still vouches for it.
- The size estimate counts an empty table as 2 bytes, not 1.
- A trade right after a migrating load stores the schema version with the migrated data. Before, the
  record kept the old version, and the next load ran the migrations again on migrated data.
- Data that contains itself no longer breaks every save: the copy a save takes recursed forever on a
  cycle, before the check could refuse it.

### Changed

- One bad value no longer costs the play around it. A value a data store cannot hold (a string that is
  not UTF-8, NaN, a function, a cycle) is repaired in what is stored, and each repair is reported once
  with its path. Before, every save of the session was refused until the game removed the value. Only
  a table's shape and the size limit still refuse the write. In the `poison` benchmark this loses 0
  steps, where it lost 204.
- Faster hand-overs: while a live owner hands over, the key is tried every half second. A dead owner's
  beat is looked at again the moment it could be judged dead. Slowest open in the benchmark: hand-over
  4.5 s to 3.2 s, three servers at once 8.2 s to 4.4 s, after a crash 10.0 s to 9.1 s.
- `restore` returns `purchasesSince`, the purchases granted after the restored version. The restored
  data no longer holds them and they stay granted, so the game must make them good; before, they were
  lost silently. The record notes the restore in `MetaData.KeepBlox.restored`.
- The snapshot a save takes is copied about 3x faster (one engine clone per table): the one step of a
  save that cannot be spread over frames. The check's text is also joined a chunk at a time inside the
  sliced walk, not all at once at its end. A 1 MB profile's longest frame stretch fell from 9.1 ms to
  4.3 ms.

### Added

- `tests/Mutate.luau`: mutation adequacy of the suite. 37 mutants, each a slip in code that keeps a
  guarantee, must each fail the suite.
- Differential fuzzing of the save check against the store's encoding.
- Releases you can roll back. A migration may be `{ up, down }`, and a store's `writeVersion` stores
  data at an older version: saves, trades, new profiles and MemoryStore snapshots alike. The release
  before it then reads everything, so a rollback locks no player out. `KeepBlox.migrateDown` tests the
  down steps on fixtures.
- The Wally and pesde packages, `xopoiii/keepblox` (0.1.0 is published on both).

## 0.1.0 - 2026-09-29

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
- A server heartbeat in MemoryStore: a dead server's keys are taken within about 10 s, a live owner
  hears a hand-over request without MessagingService, and each beat carries snapshots of changed
  profiles, so a crash loses about one 4 s beat of play. Profiles too large for a snapshot are written
  every 30 s (`renewFallback`); the data store is written every 300 s otherwise (`renew`).
- Offline and admin edits (`store:edit`, `LoadOptions.quiet`) that never kick a player.
- Trades (`store:trade`) that land in both profiles or in neither, whatever dies when.
- Shared documents (`KeepBlox.shared`) updated atomically from any server, with `watch`.
- Leaderboards (`leaderboards`, `store:leaderboard`) mirrored to ordered data stores.
- Importers (`KeepBlox.importers`) for DocumentService, Lapis, DataKeep, DataStore2 and Suphi's
  DataStore Module.
- Optional compression for large profiles (`compress`), Studio modes (`studio = "memory" | "copy"`),
  `store:close()` for tests, and roblox-ts declarations (`types/index.d.ts`).
- Benchmarks against ProfileStore, ProfileService, DocumentService, Lapis, DataStore2 and Suphi's
  DataStore Module (`bench/Report.luau`, `bench/Benchmarks.md`), and a documentation site (`docs/`).

### Fixed

- A new profile ran every migration on the template.
- A quick rejoin into the same server failed with "open" while this server was still releasing.
- A save loop queued one write per call; manual saves now join the one waiting.
