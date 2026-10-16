--!strict
--- A change applied once, though its call is tried again or lands late (issue 41).
---
--- A data store call that fails or times out may still have gone through: "a failed write does not
--- always guarantee that the backend write did not occur" (error-codes-and-limits), and a call the
--- library stops waiting for keeps running in the engine (see Call). A change that adds to what is
--- stored (a bank's `+= 100`, one more message in a queue) would then land twice: once by the call that
--- seemed to fail, once by its retry. Two tools keep it to once.
---
--- - **Ids.** Each logical call takes one id, the same for all its tries, and its transform records it in
---   the record by the same write that makes the change. A transform that finds its id already there
---   changes nothing and answers with what is stored. UpdateAsync writes only on the version it read
---   (another server's write in between runs the transform again), so a late try and a retry cannot
---   both find the id missing and both write.
--- - **A deadline in the transform.** A transform runs on the server that called, so it can read that
---   server's monotonic clock: past `lifetime` seconds from the call's start it changes nothing. An id
---   is needed only while a try of its call may still apply, and it is forgotten `lifetime + SKEW`
---   seconds after the call started, by the clock of the server that writes next (`SKEW` covers how far
---   two servers' clocks may disagree). `KEEP` caps how many ids one record holds: past it the oldest
---   go first, so the guarantee holds while fewer than `KEEP` other calls change the same key within
---   that time.
--- - **Fences.** A write that replaces what is stored (a session's save) is idempotent, but a late one
---   could put older data over newer. Such writes carry `Once.stamp()`, a number that only grows on a
---   server, and a write whose stamp is not above the one stored changes nothing.
---
--- An id is stored as `{id, at}`: the id and the wall clock (os.time) of the server that started it.

--> At most this many ids are kept in one list.
const KEEP = 100
--> Seconds two servers' wall clocks may disagree by, as far as forgetting an id goes.
const SKEW = 600

export type Entry = { any } -- {id, at}

local counter = 0

const Once = {}

Once.KEEP = KEEP
Once.SKEW = SKEW

--> A number above every number this server has handed out before.
function Once.stamp(): number
	counter += 1
	return counter
end

--> Whether a write stamped `stamp` by the session at `loadCount` may land on a record whose state is
--> `ours`: its stamp is above the stored one for that load. The stamp is then stored. Nil: unfenced.
function Once.fence(ours: { fence: { number }? }, loadCount: number, stamp: number?): boolean
	if stamp == nil then
		return true
	end
	const stored = ours.fence
	if type(stored) == "table" and stored[1] == loadCount and type(stored[2]) == "number" and stored[2] >= stamp then
		return false
	end
	ours.fence = { loadCount, stamp }
	return true
end

--> Whether `list` (a stored list, any shape) holds `id`.
function Once.seen(list: any, id: string): boolean
	if type(list) ~= "table" then
		return false
	end
	for _, entry in list do
		if type(entry) == "table" and entry[1] == id then
			return true
		end
	end
	return false
end

--> `list` (a stored list, any shape) with `id` added, started at wall clock `at`; ids older than `keep`
--> seconds by `now`, and the oldest past `KEEP`, are left out.
function Once.note(list: any, id: string, at: number, now: number, keep: number): { Entry }
	const kept: { Entry } = {}
	if type(list) == "table" then
		for _, entry in list do
			if
				type(entry) == "table"
				and type(entry[1]) == "string"
				and type(entry[2]) == "number"
				and now - entry[2] <= keep
			then
				table.insert(kept, { entry[1], entry[2] })
			end
		end
	end
	table.insert(kept, { id, at })
	while #kept > KEEP do
		table.remove(kept, 1)
	end
	return kept
end

return Once
