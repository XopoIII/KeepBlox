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
---   messages already processed into it. Profiles over `snapshotBytes`, holding buffers, or in a trade
---   have none; they are written at `renewFallback` instead.
--- A newcomer that takes over a server's key takes its snapshot too, when it is newer than the stored
--- data (see Open). One entry for all of a server's profiles keeps the cost to one call a beat per store.
--- The data store transform still decides who may write, so a wrong verdict here can at worst end a
--- live session early, never let two servers write (guarantee 2).
const Call = require("./Call")
const Codec = require("./Codec")
const Record = require("./Record")
const Types = require("./Types")
const Validate = require("./Validate")

--> What a newcomer has seen of one owner's beat. `loadCount` is the owner's session it watches: the
--> hand-over request it writes names it.
export type Watch = {
	asked: boolean,
	loadCount: number,
	deadSince: number?,
	count: number?,
	countSince: number?,
}

--> The keys a beat was asked to hand over, each with the load count of the session asked for (true for
--> a request that names none).
export type Requests = { [string]: number | true }

export type Snapshot = { c: number, q: number, v: number, d: any, rc: { string }, m: { number } }

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

-- The snapshots this beat carries, and which sessions are covered: by a snapshot, or because the store
-- already holds their data.
const function snapshots(
	context: Types.Context,
	sessions: { [string]: Types.Session }
): ({ [string]: Snapshot }, { [Types.Session]: boolean })
	const cap = context.config.snapshotBytes
	const taken: { [string]: Snapshot } = {}
	const covered: { [Types.Session]: boolean } = {}
	local total = 0
	for key, session in sessions do
		if not session.active or session.releasing or session.trading or session.storedSize > 4 * cap then
			continue
		end
		const data = session.profile.Data
		const encoded = Validate.check(data, "Data", cap)
		if encoded == nil or Codec.hasBuffer(data) then
			continue
		elseif encoded.text == session.storedText then
			covered[session] = true
			continue
		elseif total + encoded.size > ENTRY_SHARE then
			continue
		end
		if encoded.text ~= session.snapText then
			session.snapSeq += 1
			session.snapText = encoded.text
		end
		const processed = session.inbox:processed()
		const consumed = {}
		for index in processed do
			table.insert(consumed, index)
		end
		session.good = {
			text = encoded.text,
			size = encoded.size,
			data = Record.copy(data),
			consumed = table.clone(processed),
			receipts = table.clone(session.receipts),
		}
		taken[key] = {
			c = session.loadCount,
			q = session.snapSeq,
			v = context.plan.version,
			d = Record.copy(data),
			rc = table.clone(session.receipts),
			m = consumed,
		}
		total += encoded.size
		covered[session] = true
	end
	return taken, covered
end

--> One beat of this server for the store of `context`: the count moves, this store's snapshots are
--> replaced, and its requests are taken out and returned (the store hands over the sessions they
--> name). Each session learns whether it is covered. Nil when the beat failed.
function Lease.beat(context: Types.Context, sessions: { [string]: Types.Session }): Requests?
	const store = map(context)
	if store == nil then
		return nil
	end
	const prefix = `{context.storeName}/`
	const taken, covered = snapshots(context, sessions)
	local requested: Requests = {}
	const ok = call(context, function(): any
		return store:UpdateAsync(context.identity.jobId, function(current: any): any
			requested = {}
			const entry = if type(current) == "table" then current else {}
			const requests, kept = {}, {}
			for id, requester in if type(entry.r) == "table" then entry.r else {} do
				if string.sub(id, 1, #prefix) == prefix then
					const fence = if type(requester) == "table" then tonumber(requester.c) else nil
					requested[string.sub(id, #prefix + 1)] = fence or true
				else
					requests[id] = requester
				end
			end
			for id, snapshot in if type(entry.s) == "table" then entry.s else {} do
				if string.sub(id, 1, #prefix) ~= prefix then
					kept[id] = snapshot
				end
			end
			for key, snapshot in taken do
				kept[prefix .. key] = snapshot
			end
			return { n = (tonumber(entry.n) or 0) + 1, r = requests, s = kept }
		end, context.config.snapshotTtl)
	end)
	for _, session in sessions do
		session.snapshotted = ok and covered[session] == true
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
function Lease.judge(context: Types.Context, jobId: string, key: string, watch: Watch, ask: boolean): string
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

--> The snapshot the server `jobId` left of `key` for session `loadCount`, when it is newer than the
--> stored data (snapshot number above `stored`); nil otherwise.
function Lease.snapshot(
	context: Types.Context,
	jobId: string,
	key: string,
	loadCount: number,
	stored: number
): Snapshot?
	const entry = Lease.read(context, jobId, key, false)
	const all = if type(entry) == "table" and type(entry.s) == "table" then entry.s else nil
	const snapshot = if all then all[`{context.storeName}/{key}`] else nil
	if type(snapshot) ~= "table" or snapshot.c ~= loadCount or type(snapshot.q) ~= "number" or snapshot.q <= stored then
		return nil
	end
	return snapshot
end

return Lease
