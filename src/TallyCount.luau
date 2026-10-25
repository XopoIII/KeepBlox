--!strict
--- One key of a tally on one server (see Tally): what was added here and is not written yet, the batch
--- in flight, and the newest each shard was seen.
---
--- The total is the sum of the shards as seen, with what this server added and has not seen land on
--- top. A batch is known to have landed once its serial is seen in this server's shard, by its own write
--- or by a read, and in that same step the shard's count that includes it is taken: so the batch is never
--- counted twice, nor left out, whichever of the two comes first.
const Call = require("./Call")
const Report = require("./Report")
const Services = require("./Services")
const TallyShard = require("./TallyShard")

export type Batch = { serial: number, amount: number }

export type Watcher = { handler: (total: number) -> () }

export type Count = {
	--> Added here and not in a batch yet.
	pending: number,
	--> Sent, and not known to have landed.
	batch: Batch?,
	--> The serial of this server's last batch known to have landed.
	serial: number,
	--> A write of the batch is in flight.
	flying: boolean,
	--> The newest each shard was seen, by its number.
	shards: { [number]: TallyShard.Seen },
	watchers: { Watcher },
	--> The total the watchers were last told.
	told: number?,
	--> A failed write, or a read, was reported; cleared once one goes through.
	failing: boolean,
	unread: boolean,
}

export type Context = {
	clock: Services.Clock,
	--> The data store, read at each call: it moves to memory when Studio has no access.
	store: () -> Services.DataStore,
	--> This tally's id in the shards it writes.
	server: string,
	--> The shard this server writes.
	mine: number,
	shards: number,
	remember: number,
	timeout: number,
	report: Report.Report,
}

const TallyCount = {}

function TallyCount.new(): Count
	return {
		pending = 0,
		batch = nil,
		serial = 0,
		flying = false,
		shards = {},
		watchers = {},
		told = nil,
		failing = false,
		unread = false,
	}
end

--> The data store key of shard `shard` of `key`.
function TallyCount.shardKey(key: string, shard: number): string
	return `{key}/{shard}`
end

--> The shard the tally `server` writes, of `shards`: spread by its id, the same on every call.
function TallyCount.pick(server: string, shards: number): number
	local hash = 0
	for index = 1, #server do
		hash = (hash * 31 + string.byte(server, index)) % 2147483647
	end
	return hash % shards + 1
end

--> Every server's count of the key as seen, with this server's adds not seen land yet.
function TallyCount.total(count: Count): number
	local total = count.pending + (if count.batch then count.batch.amount else 0)
	for _, seen in count.shards do
		total += seen.count
	end
	return total
end

--> Takes what shard `shard` was seen to hold, if it is newer than what was known, and settles the batch
--> when this server's shard shows it landed.
function TallyCount.note(count: Count, shard: number, seen: TallyShard.Seen, mine: number)
	const known = count.shards[shard]
	if known == nil or seen.version > known.version then
		count.shards[shard] = seen
	end
	const batch = count.batch
	if shard == mine and batch and seen.serial and seen.serial >= batch.serial then
		count.batch = nil
		count.serial = batch.serial
	end
end

--> One try at writing what this server added to `key` since its last batch landed. True when nothing
--> is left unwritten; false while a batch waits, to be tried again.
function TallyCount.write(context: Context, key: string, count: Count): boolean
	if count.flying then
		return false
	end
	if count.batch == nil then
		if count.pending == 0 then
			return true
		end
		count.batch = { serial = count.serial + 1, amount = count.pending }
		count.pending = 0
	end
	const batch = count.batch :: Batch
	const clock = context.clock
	const shardKey = TallyCount.shardKey(key, context.mine)
	const started = clock.now()
	local seen: TallyShard.Seen? = nil
	local foreign = false
	count.flying = true
	const ok, problem = Call.update(clock, context.timeout, context.store(), shardKey, function(value: any): any
		seen, foreign = nil, false
		-- A try the engine runs this late is one this server gave up on long ago, and the entry that
		-- would tell it apart may be gone by now (see TallyShard).
		if clock.now() - started > context.remember / 2 then
			return nil
		end
		const kind = TallyShard.classify(value)
		if kind == "foreign" then
			foreign = true
			return nil
		end
		const stored = if kind == "shard" then value else nil
		const added = TallyShard.add(stored, context.server, batch.serial, batch.amount, clock.time(), context.remember)
		seen = TallyShard.seen(added or stored, context.server)
		return added
	end)
	count.flying = false
	if ok and seen then
		TallyCount.note(count, context.mine, seen, context.mine)
		count.failing = false
		return count.batch == nil and count.pending == 0
	end
	if not count.failing then
		count.failing = true
		context.report(
			key,
			if foreign
				then `"{shardKey}" holds a value that is not a tally's: what this server adds to "{key}" is kept, not written`
				else `a batch of "{key}" could not be written ({tostring(problem)}): it is tried again`,
			"tally"
		)
	end
	return false
end

--> Reads every shard of `key`. Fails with "failed" when a read does not answer, "foreign" when a shard
--> holds a value that is not a tally's.
function TallyCount.read(context: Context, key: string, count: Count): (boolean, ("failed" | "foreign")?, string?)
	for shard = 1, context.shards do
		const shardKey = TallyCount.shardKey(key, shard)
		const ok, value = Call.run(context.clock, context.timeout, function(): any
			return (context.store():GetAsync(shardKey, false))
		end)
		if not ok then
			return false, "failed", tostring(value)
		end
		const seen = TallyShard.seen(value, context.server)
		if seen == nil then
			return false, "foreign", `"{shardKey}" holds a value that is not a tally's`
		end
		TallyCount.note(count, shard, seen, context.mine)
	end
	return true, nil, nil
end

return TallyCount
