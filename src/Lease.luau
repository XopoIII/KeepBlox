--!strict
--- A server heartbeat in MemoryStore beside the data store lock. It tells newcomers within seconds
--- whether an owner lives, carries hand-over requests when MessagingService is down, and holds recent
--- snapshots of its profiles, so a crash loses seconds of play instead of a `renew` interval.
---
--- Each server keeps one entry, `KB_servers[<JobId>] = { n, r, s }`, rewritten every `heartbeat`
--- seconds by each of its stores, and kept `snapshotTtl` seconds after the last beat:
--- - `n` counts the beats. A newcomer that sees it stand still for two beats, or finds no entry, knows
---   the server died, and takes its keys; while it moves, the server lives.
--- - `r["<store>/<key>"] = { g, c }` are requests: the owner hands those keys over at its next beat, if
---   its session there is still the one the requester saw (load count `c`), so a request that outlives
---   its session never ends the next one. A bare GUID (written by an older KeepBlox) is not fenced.
--- - `s["<store>/<key>"] = { c, q, v, d, rc, m }` is a snapshot of one open profile whose data changed
---   since it was last stored: load count, snapshot number, schema version, data, receipt ids and the
---   messages already processed into it. A profile over `snapshotBytes` has one in `x` instead, holding
---   only its edits since it was stored (see Snapshots). Profiles whose edits do not fit either, holding
---   buffers, or in a trade have none; they are written at `renewFallback` instead.
--- A newcomer that takes over a server's key takes its snapshot too, when it is newer than the stored
--- data (see Open). One entry for all of a server's profiles keeps the cost to one call a beat per store.
--- The data store transform still decides who may write, so a wrong verdict here can at worst end a
--- live session early, never let two servers write (guarantee 2).
const Call = require("./Call")
const Snapshots = require("./Snapshots")
const Types = require("./Types")

--> What a newcomer has seen of one owner's beat. `loadCount` is the owner's session it watches: the
--> hand-over request it writes names it.
export type Watch = {
	asked: boolean,
	loadCount: number,
	deadSince: number?,
	count: number?,
	countSince: number?,
	--> When the beat was last looked at, and the verdict then.
	lookedAt: number?,
	verdict: string?,
}

--> The keys a beat was asked to hand over, each with the load count of the session asked for (true for
--> a request that names none).
export type Requests = { [string]: number | true }

export type Snapshot = Snapshots.Snapshot

const MAP = "KB_servers"
-- What one store's snapshots may take of a server's entry (an entry holds at most 32 KB).
const ENTRY_SHARE = 24_000

const Lease = {}

const function map(context: Types.Context): any?
	const memory = context.services.memory
	return if memory then memory:GetSortedMap(MAP) else nil
end

-- One memory store call with the data store call's deadline; false when it failed.
const function call(context: Types.Context, fn: () -> any): (boolean, any)
	return Call.run(context.services.clock, context.config.callTimeout, fn)
end

--> Whether this store can beat in MemoryStore.
function Lease.available(context: Types.Context): boolean
	return context.services.memory ~= nil
end

--> One beat of this server for the store of `context`: the count moves, this store's snapshots are
--> replaced, and its requests are taken out and returned (the store hands over the sessions they
--> name). Each session learns whether it is covered. Nil when the beat failed. `final`: the last beat of
--> a closing server, whose releases did not land: `sessions` are those, snapshotted as they end.
function Lease.beat(context: Types.Context, sessions: { [string]: Types.Session }, final: boolean?): Requests?
	const store = map(context)
	if store == nil then
		return nil
	end
	const prefix = `{context.storeName}/`
	const taken = Snapshots.take(context, sessions, ENTRY_SHARE, final)
	local requested: Requests = {}
	const ok = call(context, function(): any
		return store:UpdateAsync(context.identity.jobId, function(current: any): any
			requested = {}
			const entry = if type(current) == "table" then current else {}
			const requests = {}
			for id, requester in if type(entry.r) == "table" then entry.r else {} do
				if string.sub(id, 1, #prefix) == prefix then
					const fence = if type(requester) == "table" then tonumber(requester.c) else nil
					requested[string.sub(id, #prefix + 1)] = fence or true
				else
					requests[id] = requester
				end
			end
			-- Other stores' snapshots stay; this store's are replaced.
			const function replace(old: any, new: { [string]: Snapshot }): { [string]: any }
				const kept = {}
				for id, snapshot in if type(old) == "table" then old else {} do
					if string.sub(id, 1, #prefix) ~= prefix then
						kept[id] = snapshot
					end
				end
				for key, snapshot in new do
					kept[prefix .. key] = snapshot
				end
				return kept
			end
			return {
				n = (tonumber(entry.n) or 0) + 1,
				r = requests,
				s = replace(entry.s, taken.whole),
				x = replace(entry.x, taken.edits),
			}
		end, context.config.snapshotTtl)
	end)
	for _, session in sessions do
		session.snapshotted = ok and taken.covered[session] == true
	end
	return if ok then requested else nil
end

--> The server `jobId`'s entry now (nil when it has none), or false when MemoryStore gave no answer.
--> With `ask`, a live server is also asked to hand `key` over, if its session there is still
--> `loadCount`.
function Lease.read(context: Types.Context, jobId: string, key: string, ask: boolean, loadCount: number?): any
	const store = map(context)
	if store == nil then
		return false
	end
	local seen: any = nil
	const ok = call(context, function(): any
		if not ask then
			seen = store:GetAsync(jobId)
			return seen
		end
		return store:UpdateAsync(jobId, function(current: any): any
			seen = current
			if type(current) ~= "table" then
				return nil
			end
			current.r = if type(current.r) == "table" then current.r else {}
			current.r[`{context.storeName}/{key}`] = { g = context.identity.guid, c = loadCount }
			return current
		end, context.config.snapshotTtl)
	end)
	return if ok then seen else false
end

--> A verdict on the server `jobId` holding `key` that a newcomer can act on: "dead" (no entry at two
--> looks at least half a `heartbeat` apart, or its count standing still for two beats), "alive" (the
--> count moves), "pending" (look again), or "unknown" (no answer). The server is asked to hand over
--> once.
const function look(context: Types.Context, jobId: string, key: string, watch: Watch, ask: boolean): string
	const clock = context.services.clock
	const now = clock.now()
	const entry = Lease.read(context, jobId, key, ask and not watch.asked, watch.loadCount)
	if entry == false then
		return "unknown"
	end
	watch.asked = watch.asked or ask
	if type(entry) ~= "table" then
		watch.count = nil
		watch.deadSince = watch.deadSince or now
		return if now - (watch.deadSince :: number) >= context.config.heartbeat / 2 then "dead" else "pending"
	end
	watch.deadSince = nil
	const count = tonumber(entry.n) or 0
	if watch.count ~= count then
		const moved = watch.count ~= nil
		watch.count, watch.countSince = count, now
		return if moved then "alive" else "pending"
	end
	-- Standing still proves nothing until two beats have passed: only a move proves a live server.
	return if now - (watch.countSince :: number) >= 2 * context.config.heartbeat then "dead" else "pending"
end

function Lease.judge(context: Types.Context, jobId: string, key: string, watch: Watch, ask: boolean): string
	const verdict = look(context, jobId, key, watch, ask)
	if verdict ~= "unknown" then
		watch.lookedAt, watch.verdict = context.services.clock.now(), verdict
	end
	return verdict
end

--> The verdict `watch` had when its beat was looked at less than a second ago, not yet "dead"; nil when
--> the beat must be looked at again. A newcomer that just looked while waiting need not look again right
--> after trying the data store: a hand-over it waits for is caught by that try a moment sooner.
function Lease.recent(context: Types.Context, watch: Watch): string?
	const lookedAt = watch.lookedAt
	if not watch.asked or lookedAt == nil or watch.verdict == "dead" then
		return nil
	end
	return if context.services.clock.now() - lookedAt < 1 then watch.verdict else nil
end

--> Seconds until `watch`'s verdict could next change (the beat judged dead), at most one: a newcomer
--> looks again then, not later.
function Lease.nextLook(context: Types.Context, watch: Watch): number
	const now = context.services.clock.now()
	const heartbeat = context.config.heartbeat
	local due = 1
	if watch.deadSince then
		due = watch.deadSince + heartbeat / 2 - now
	elseif watch.countSince then
		due = watch.countSince + 2 * heartbeat - now
	end
	return math.clamp(due, 0.05, 1)
end

--> The snapshot the server `jobId` left of `key` for session `loadCount`, when it is newer than the
--> stored data (snapshot number above `stored`); nil otherwise. And whether MemoryStore answered: with
--> no answer, nobody knows whether there is one.
function Lease.snapshot(
	context: Types.Context,
	jobId: string,
	key: string,
	loadCount: number,
	stored: number
): (Snapshot?, boolean)
	const entry = Lease.read(context, jobId, key, false)
	const id = `{context.storeName}/{key}`
	local snapshot: any = nil
	for _, field in { "s", "x" } do
		const all = if type(entry) == "table" and type(entry[field]) == "table" then entry[field] else nil
		snapshot = snapshot or (if all then all[id] else nil)
	end
	if type(snapshot) ~= "table" or snapshot.c ~= loadCount or type(snapshot.q) ~= "number" or snapshot.q <= stored then
		return nil, entry ~= false
	end
	return snapshot, true
end

return Lease
