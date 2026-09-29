--!strict
--- A server heartbeat in MemoryStore beside the data store lock, so a dead owner is known within
--- seconds and a live one hears a hand-over request even when MessagingService is down.
---
--- Each server keeps one entry, `KB_servers[<JobId>]`, alive from the moment a store starts: every store
--- rewrites it every `heartbeat` seconds, and it expires `leaseTtl` seconds after the last beat. One
--- entry for all of a server's profiles keeps the cost to one call a beat per store, whatever the
--- player count. A record whose owner beats says so (`MetaData.KeepBlox.memory`). A newcomer that finds
--- the key held looks up the owner's server:
--- - no entry, at two looks at least half a `heartbeat` apart: the server died, and the key is taken;
--- - an entry: the server lives; the newcomer adds its request (`r["<store>/<key>"]`), and the owner
---   hands over at its next beat;
--- - no answer (an outage): the data store lease rule decides, as without MemoryStore.
--- The data store transform still decides who may write, so a wrong verdict here can at worst end a
--- live session early, never let two servers write (guarantee 2).
const Call = require("./Call")
const Session = require("./Session")

export type Watch = { asked: boolean, deadSince: number?, aliveSince: number? }

const MAP = "KB_servers"

const Lease = {}

const function map(context: Session.Context): any?
	const memory = context.services.memory
	return if memory then memory:GetSortedMap(MAP) else nil
end

-- One memory store call with the data store call's deadline; false when it failed.
const function call(context: Session.Context, fn: () -> any): (boolean, any)
	return Call.run(context.services.clock, context.config.callTimeout, fn)
end

--> Whether this store can beat in MemoryStore.
function Lease.available(context: Session.Context): boolean
	return context.services.memory ~= nil
end

--> One beat of this server for the store of `context`. Requests for this store's keys are taken out
--> and returned; the store hands those sessions over. Nil when the beat failed.
function Lease.beat(context: Session.Context): { string }?
	const store = map(context)
	if store == nil then
		return nil
	end
	const prefix = `{context.storeName}/`
	local requested: { string } = {}
	const ok = call(context, function(): any
		return store:UpdateAsync(context.identity.jobId, function(current: any): any
			requested = {}
			const requests = if type(current) == "table" and type(current.r) == "table" then current.r else {}
			const kept = {}
			for id, requester in requests do
				if string.sub(id, 1, #prefix) == prefix then
					table.insert(requested, string.sub(id, #prefix + 1))
				else
					kept[id] = requester
				end
			end
			return { r = kept }
		end, context.config.leaseTtl)
	end)
	return if ok then requested else nil
end

--> Whether the server `jobId` still beats. With `ask`, a live server is also asked to hand `key` over.
function Lease.look(context: Session.Context, jobId: string, key: string, ask: boolean): "alive" | "dead" | "unknown"
	const store = map(context)
	if store == nil then
		return "unknown"
	end
	local seen: any = nil
	const ok = call(context, function(): any
		if not ask then
			seen = store:GetAsync(jobId)
			return seen
		end
		return store:UpdateAsync(jobId, function(current: any): any
			seen = current
			if current == nil then
				return nil
			end
			current.r = if type(current.r) == "table" then current.r else {}
			current.r[`{context.storeName}/{key}`] = context.identity.guid
			return current
			-- Two beats: a live server rewrites the entry (and sees the request) before then; a dead
			-- one's entry goes sooner than its full expiry would allow.
		end, 2 * context.config.heartbeat)
	end)
	if not ok then
		return "unknown"
	end
	return if seen == nil then "dead" else "alive"
end

--> A verdict on the server `jobId` holding `key` that a newcomer can act on: "dead" (no entry at two
--> looks at least half a `heartbeat` apart), "alive", "pending" (no entry yet: look again), or
--> "unknown". The server is asked to hand over once: asking rewrites its entry, and asking every time
--> would keep a dead server's entry from ever expiring.
function Lease.judge(context: Session.Context, jobId: string, key: string, watch: Watch, ask: boolean): string
	const now = context.services.clock.now()
	const verdict = Lease.look(context, jobId, key, ask and not watch.asked)
	watch.asked = watch.asked or ask
	if verdict == "dead" then
		-- A server that comes back is asked again: the request went with its old entry.
		watch.asked = false
		watch.aliveSince = nil
		watch.deadSince = watch.deadSince or now
		return if now - (watch.deadSince :: number) >= context.config.heartbeat / 2 then "dead" else "pending"
	end
	watch.deadSince = nil
	if verdict == "alive" then
		watch.aliveSince = watch.aliveSince or now
	end
	return verdict
end

return Lease
