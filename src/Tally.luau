--!strict
--- A tally: numbers every server adds to, summed across the whole game and read back by every server.
--- For what players build together: a community goal, a season's total, a world boss's damage.
---
---     const gives = KeepBlox.tally("Gives")
---     gives:add("harvest", 1) -- counted here at once, written with this server's next batch
---     gives:watch("harvest", function(total) showGoal(total) end) -- every server's, read every minute
---     print(gives:total("harvest")) -- the same number, now, without yielding
---
--- A key's count is spread over `shards` keys of the data store `name`, "<key>/1" to "<key>/<shards>".
--- Each server writes to one of them, chosen when the tally opens, and only every `interval` seconds:
--- what was added there meanwhile goes as one batch in one UpdateAsync, and lands once though its call
--- is tried again or lands late (see TallyShard). Servers adding at once share the shards, so a shard
--- takes about one write a server in `shards` an interval, whatever the number of adds. A watched key is
--- read every `interval` seconds, one GetAsync a shard. `total` is the sum of what was read, with this
--- server's adds not yet seen land on top: a player sees their own add at once, and everyone else's
--- within about two intervals.
---
--- What it costs a server each `interval`: one UpdateAsync for each key added to, and `shards` reads for
--- each key watched. A turn writes nothing while fewer than `reserve` standard writes are left in the
--- server's budget, and reads nothing while fewer than `shards + reserve` standard reads are, so saves
--- always have theirs; what waits goes at the next turn.
---
--- What it does not promise. Adds still unwritten when a server stops without closing (a crash) are
--- lost: at most an interval's. A server that closes writes them first, within `shutdownDeadline`. A
--- batch that cannot land for `remember` seconds may count twice once it does. `shards` is fixed for a
--- name: a server that reads fewer shards than another writes misses those.
---
--- Use a data store of its own. In Studio, a place that cannot reach live data keeps the counts in
--- memory and says so once through `onError` (see Studio).
const Config = require("./Config")
const Report = require("./Report")
const Services = require("./Services")
const Signal = require("./Signal")
const Studio = require("./Studio")
const TallyCount = require("./TallyCount")

--> The longest key a data store takes.
const KEY_LIMIT = 50

export type Options = {
	--> Seconds between a server's batches, and between its reads of the keys watched. Default 60.
	interval: number?,
	--> Keys a count is spread over. Default 8. Fixed for the tally's name (see the header).
	shards: number?,
	--> Seconds a shard keeps the entry of a server that stopped writing there, and so how long a batch is
	--> safe to try again. Default a day.
	remember: number?,
	--> Standard requests left in the server's budget below which a turn waits. Default 10.
	reserve: number?,
	services: Services.Services?,
	config: Config.Overrides?,
	mock: (boolean | string)?,
}

export type Result = { ok: true, total: number } | { ok: false, reason: "foreign" | "failed", message: string? }

export type Tally = {
	name: string,
	--> Fires `(key, message, kind)` for a problem worth logging: a batch that could not be written, a
	--> watched key that could not be read, a shard holding something else (kind "tally"), and Studio
	--> without live data (kind "studio").
	onError: Signal.Signal<string, string, Report.ErrorKind>,
	--> Adds `amount` to `key`: counted here at once, written with this server's next batch. Never yields.
	add: (self: Tally, key: string, amount: number) -> (),
	--> Every server's count of `key` as last read, with this server's adds since. Never yields.
	total: (self: Tally, key: string) -> number,
	--> Reads every shard of `key` now and gives the total. Yields.
	read: (self: Tally, key: string) -> Result,
	--> Writes every key's batch now, one try each. True when nothing is left unwritten. Yields.
	flush: (self: Tally) -> boolean,
	--> Reads `key` at once and then every `interval` while it is watched, and calls `handler(total)` with
	--> the total after the first read and whenever it changes, by a read or by this server's add.
	watch: (self: Tally, key: string, handler: (total: number) -> ()) -> Services.Connection,
}

const Tally = {}

function Tally.new(name: string, options: Options?): Tally
	assert(type(name) == "string" and #name > 0, "KeepBlox: a tally needs a name")
	const given: Options = options or {}
	const interval = given.interval or 60
	const shards = given.shards or 8
	const remember = given.remember or 86400
	const reserve = given.reserve or 10
	assert(type(interval) == "number" and interval > 0, "KeepBlox: a tally's interval is seconds above zero")
	assert(type(shards) == "number" and shards >= 1 and shards % 1 == 0, "KeepBlox: a tally's shards is a whole number")
	assert(type(remember) == "number" and remember > 0, "KeepBlox: a tally's remember is seconds above zero")
	const config = Config.resolve(given.config)
	const origin = given.services or require("./RobloxServices").build()
	const clock = origin.clock
	const onError: Signal.Signal<string, string, Report.ErrorKind> = Signal.new(clock.spawn)
	const report = function(key: string, message: string, kind: Report.ErrorKind)
		onError:fire(key, message, kind)
	end
	const chosen = Studio.choose(origin, name, if given.mock == true then "tally" else given.mock, "live")
	const prepare = Studio.guard(chosen, name, report)
	const server = origin.guid()
	const context: TallyCount.Context = {
		clock = clock,
		store = function(): Services.DataStore
			return chosen.dataStore
		end,
		server = server,
		mine = TallyCount.pick(server, shards),
		shards = shards,
		remember = remember,
		timeout = config.callTimeout,
		report = report,
	}
	const counts: { [string]: TallyCount.Count } = {}
	local running, closing = false, false

	const function countOf(key: string): TallyCount.Count
		assert(type(key) == "string" and #key > 0, "KeepBlox: a tally's key is a string")
		assert(
			#TallyCount.shardKey(key, shards) <= KEY_LIMIT,
			`KeepBlox: "{TallyCount.shardKey(key, shards)}" is over the {KEY_LIMIT} characters a key may have`
		)
		local count = counts[key]
		if not count then
			count = TallyCount.new()
			counts[key] = count
		end
		return count
	end

	-- The keys now: a write or a read yields, and an add meanwhile may open a new one.
	const function keys(): { string }
		const list: { string } = {}
		for key in counts do
			table.insert(list, key)
		end
		return list
	end

	-- Tells the watchers of `count` its total when it changed since they were last told.
	const function tell(count: TallyCount.Count)
		const total = TallyCount.total(count)
		if total == count.told then
			return
		end
		count.told = total
		for _, watcher in table.clone(count.watchers) do
			clock.spawn(function()
				watcher.handler(total)
			end)
		end
	end

	const function read(key: string, count: TallyCount.Count): Result
		const ok, reason, message = TallyCount.read(context, key, count)
		tell(count)
		if not ok then
			if not count.unread then
				count.unread = true
				report(key, `"{key}" could not be read: {message}`, "tally")
			end
			return { ok = false, reason = reason :: any, message = message }
		end
		count.unread = false
		return { ok = true, total = TallyCount.total(count) }
	end

	const function budget(kind: Services.RequestType): number
		return chosen.services.dataStores:GetRequestBudgetForRequestType(kind)
	end

	-- One turn: every key's batch written, then every watched key read, while the budget allows.
	const function turn()
		prepare()
		for _, key in keys() do
			if budget("StandardWrite") < reserve then
				break
			end
			TallyCount.write(context, key, counts[key])
			tell(counts[key])
		end
		for _, key in keys() do
			const count = counts[key]
			if #count.watchers > 0 then
				if budget("StandardRead") < shards + reserve then
					break
				end
				read(key, count)
			end
		end
	end

	const function start()
		if running then
			return
		end
		running = true
		clock.spawn(function()
			while not closing do
				clock.wait(interval)
				if not closing then
					turn()
				end
			end
		end)
	end

	-- On shutdown every batch is written, tried again with backoff until the deadline.
	origin.bindToClose(function()
		closing = true
		if next(counts) == nil then
			return
		end
		const deadline = clock.now() + config.shutdownDeadline
		local delay = config.backoffMin
		while true do
			local left = false
			for _, key in keys() do
				if not TallyCount.write(context, key, counts[key]) then
					left = true
				end
			end
			if not left or clock.now() + delay > deadline then
				return
			end
			clock.wait(delay)
			delay = math.min(delay * 2, config.backoffMax)
		end
	end)

	return {
		name = name,
		onError = onError,
		add = function(_: Tally, key: string, amount: number)
			assert(
				type(amount) == "number" and amount == amount and math.abs(amount) ~= math.huge,
				"KeepBlox: a tally adds a finite number"
			)
			const count = countOf(key)
			count.pending += amount
			start()
			tell(count)
		end,
		total = function(_: Tally, key: string): number
			const count = counts[key]
			return if count then TallyCount.total(count) else 0
		end,
		read = function(_: Tally, key: string): Result
			prepare()
			return read(key, countOf(key))
		end,
		flush = function(_: Tally): boolean
			prepare()
			local done = true
			for _, key in keys() do
				if not TallyCount.write(context, key, counts[key]) then
					done = false
				end
				tell(counts[key])
			end
			return done
		end,
		watch = function(_: Tally, key: string, handler: (total: number) -> ()): Services.Connection
			assert(type(handler) == "function", "KeepBlox: watch needs a function")
			const count = countOf(key)
			const watcher: TallyCount.Watcher = { handler = handler }
			local connected = true
			start()
			-- Read at once, since a server that has just opened knows nothing of the others' adds yet. The
			-- watcher joins the others after that read, told the total it found, so it is told it once.
			clock.spawn(function()
				prepare()
				read(key, count)
				if connected then
					table.insert(count.watchers, watcher)
					handler(TallyCount.total(count))
				end
			end)
			return {
				Disconnect = function(_: Services.Connection)
					connected = false
					const index = table.find(count.watchers, watcher)
					if index then
						table.remove(count.watchers, index)
					end
				end,
			}
		end,
	}
end

return Tally
