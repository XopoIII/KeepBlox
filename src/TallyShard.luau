--!strict
--- One shard of a tally (see Tally): the key "<key>/<n>", holding a part of the count and what each
--- server that wrote there lately wrote last.
---
--- A server adds what it gathered as one batch: an amount and a serial, one more than its last batch's
--- on that key. The shard keeps each server's last serial that landed, and when (`{serial, at}`, by the
--- writer's wall clock). A try that finds its serial there already changes nothing, so a batch lands
--- once though its call is tried again or lands late: a write that seemed to fail may have gone through
--- (error-codes-and-limits). Unlike the id lists of Once, this keeps one entry a server, not one a call,
--- so a batch stays safe to try again for as long as its server's entry is kept: `remember` seconds
--- after that server's last write there. A server's batches on a key are sent one at a time, so a
--- serial below the stored one is an old try as surely as an equal one.
---
--- `version` grows by one with every write, so a reader keeps the newer of two answers for one shard.

--> What the format field holds; any other value under a shard's key is foreign.
const FORMAT = 1

export type Stored = {
	tally: number,
	count: number,
	version: number,
	servers: { [string]: { number } },
}

--> What a read of a shard tells: its count, its version, and the serial `server` last landed there.
export type Seen = { count: number, version: number, serial: number? }

const TallyShard = {}

TallyShard.FORMAT = FORMAT

--> "empty" for nothing stored, "shard" for a shard, "foreign" for anything else.
function TallyShard.classify(value: any): "empty" | "shard" | "foreign"
	if value == nil then
		return "empty"
	elseif
		type(value) == "table"
		and value.tally == FORMAT
		and type(value.count) == "number"
		and type(value.version) == "number"
		and type(value.servers) == "table"
	then
		return "shard"
	end
	return "foreign"
end

--> What `value` (a stored shard, or nil) tells `server`; nil when it is foreign.
function TallyShard.seen(value: any, server: string): Seen?
	const kind = TallyShard.classify(value)
	if kind == "empty" then
		return { count = 0, version = 0, serial = nil }
	elseif kind == "foreign" then
		return nil
	end
	const entry = value.servers[server]
	const serial = if type(entry) == "table" and type(entry[1]) == "number" then entry[1] else nil
	return { count = value.count, version = value.version, serial = serial }
end

--> `value` (a stored shard, or nil for none) with `server`'s batch `serial` of `amount` added at wall
--> clock `now`, and the entries of servers silent for over `remember` seconds left out; nil when that
--> batch, or a later one of the same server, is there already.
function TallyShard.add(
	value: Stored?,
	server: string,
	serial: number,
	amount: number,
	now: number,
	remember: number
): Stored?
	const servers: { [string]: { number } } = {}
	if value then
		const entry = value.servers[server]
		if type(entry) == "table" and type(entry[1]) == "number" and entry[1] >= serial then
			return nil
		end
		for id, other in value.servers do
			if
				type(other) == "table"
				and type(other[1]) == "number"
				and type(other[2]) == "number"
				and now - other[2] <= remember
			then
				servers[id] = { other[1], other[2] }
			end
		end
	end
	servers[server] = { serial, now }
	return {
		tally = FORMAT,
		count = (if value then value.count else 0) + amount,
		version = (if value then value.version else 0) + 1,
		servers = servers,
	}
end

return TallyShard
