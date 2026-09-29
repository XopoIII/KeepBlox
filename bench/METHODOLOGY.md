## Methodology

**One simulator for every library.** Each library runs unmodified, one copy per virtual server, in
`tests/sim/RobloxEnv`: `game`, `task`, `require`, the DataStore and MessagingService are fakes that copy
the documented engine behaviour (each fake cites its Roblox doc page). Time is virtual and every service
call is a yield point; the seed decides the interleaving, so any run replays exactly from its seed. The
rival libraries are downloaded at exact pins by `bench/download.luau`; ProfileStore and Suphi's DataStore
Module (which ships only as a Roblox asset) are vendored in `tests/reference`.

**One way to use each library.** Each adapter (`tests/sim/*Adapter.luau`, `bench/adapters/`) uses its
library the way its own documentation tells a game to: load on join, release on leave, kick when the
session ends. An adapter translates, it never adds behaviour. Libraries with no "saved, with this data"
signal are acknowledged at the service boundary: a write the library made commits while its session is
live, and the data that write stored counts as acknowledged (it is exactly what the store holds).

**The scenarios** (`tests/sim/Scenarios.luau`): a player leaves and rejoins elsewhere (`rejoin`), arrives
on another server before the old one noticed (`handoff`), their server crashes (`crash`), their server
is cut off from MessagingService (`partitioned`), three servers want the same key (`thirdRequester`), 50
players on a closing server (`shutdown`), the data store fails for minutes (`outage`), the game writes a
value the store cannot hold (`poison`), and everything at once for many players (`soup`).

**The columns.**
- *Violations*: breaches the ledger (`tests/sim/Ledger.luau`) saw. `ack-lost`: a save the library
  acknowledged was later missing. `foreign-write`: a server changed the data while another held the lock.
  `load-count-backwards`: the session counter went back. For a library that keeps no lock in the stored
  value (DataStore2), only `ack-lost` applies.
- *Progress lost*: the most steps of play a reload did not have. It is measured only on loads that
  succeed, so read it with *player locked out*: a library whose lock outlives a crashed server (for
  10 or 30 minutes) loses nothing on paper because the player cannot load at all.
- *Stale owner*: how long a server kept a session active after another server had opened the same key.
  Trades and purchases made meanwhile are made on a copy that will be overwritten.
- *Slowest open* and *failed opens*: how long a player waits for their data, and how many never get it.
  An open whose player had already left is neither: it is not counted.
- *Library errors*: errors the library threw into the game's threads.
- *Requests per player-hour*: data store requests, by the budget they draw on, over an hour of play.
  The per-server budget (60 + 40 per player a minute for reads and writes) is shared by everything the
  game does, so a library that spends less leaves more to the game.
- *MemoryStore units*: request units per player-hour against MemoryStore's own quota (1000 + 120 per
  user a minute, experience-wide). KeepBlox's heartbeat and Suphi's lock live there.

**What is not compared.** CPU time: the engine serializes values natively in Roblox, and in the
simulator it does not, so a library's own CPU cost cannot be separated fairly. KeepBlox's own frame cost
is in `bench/Run.luau`.
