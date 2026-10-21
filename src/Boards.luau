--!strict
--- Leaderboards beside the profiles: chosen numbers mirrored into OrderedDataStores, and read back
--- sorted.
---
---     const store = KeepBlox.store("Profiles", {
---         template = { coins = 0, wins = 0 },
---         leaderboards = {
---             coins = function(data) return data.coins end,
---             wins = function(data) return data.wins end,
---             -- starts again empty every week, from Monday 00:00 UTC (1970-01-05 was a Monday)
---             weekly = { read = function(data, week) return data.weekly end, period = { length = 604800, origin = 345600 } },
---         },
---     })
---     const top = store:leaderboard("coins", { count = 10 })  -- { {key = "u_1", value = 900}, ... }
---
--- A board is the ordered data store "<store>__<board>", keyed by profile key; a board with a period
--- is one store a period, "<store>__<board>_<n>", where n counts the periods from `origin` by this
--- server's wall clock. After a save stores a profile, each board's value is written if it changed,
--- at most once per `interval` seconds per profile, and always on the release. It is a mirror,
--- written after the save and not with it: the profile is the truth, and a board can trail it by up
--- to `interval`. A value is an integer (it is floored); nil removes the key from the board.
---
--- Ordered writes have their own small budget (30 + 5 per player a minute) and reads a smaller one
--- (5 + 2 per player): a write waits for the next save when that budget is spent, and a read keeps
--- each answer for `cache` seconds, and answers from its last one while the budget is spent.
const Call = require("./Call")
const Report = require("./Report")
const Services = require("./Services")

--> A board's value for a profile's data; a board with a period is also told the period it is for.
export type Read = (data: any, period: number) -> number?
--> A board that starts again empty every `length` seconds, counted from the Unix time `origin`
--> (default 0).
export type Period = { length: number, origin: number? }
export type Board = ((data: any) -> number?) | { read: Read, period: Period }

export type Options = {
	--> Seconds between one profile's writes to its boards (default 60).
	interval: number?,
	--> Seconds a `leaderboard` answer is kept (default 60).
	cache: number?,
}

export type Entry = { key: string, value: number }

export type Query = {
	--> How many entries, from the top (default 10, at most 100).
	count: number?,
	--> Lowest first (default: highest first).
	ascending: boolean?,
	--> Which period of a board with a period (default: the current one).
	period: number?,
}

export type Boards = {
	--> Called after a save stored `data` for `key`; `final` on the release.
	stored: (self: Boards, key: string, data: any, final: boolean) -> (),
	top: (self: Boards, name: string, query: Query?) -> { Entry },
	above: (self: Boards, name: string, value: number, query: Query?) -> Entry?,
	period: (self: Boards, name: string) -> number?,
}

type Kept = { read: (data: any, period: number?) -> number?, length: number?, origin: number }
type Mirror = { values: { [string]: number? }, periods: { [string]: number? }, at: number }
type Answer = { at: number, entries: { Entry } }

const Boards = {}

const function keep(name: string, board: Board): Kept
	assert(type(name) == "string", "KeepBlox: a leaderboard is a name and a function")
	if type(board) == "function" then
		return { read = board, origin = 0 }
	end
	assert(
		type(board) == "table" and type(board.read) == "function",
		"KeepBlox: a leaderboard is a name and a function"
	)
	const period = board.period
	assert(
		type(period) == "table" and type(period.length) == "number" and period.length > 0,
		`KeepBlox: leaderboard "{name}" needs a period length, a positive number of seconds`
	)
	assert(
		period.origin == nil or type(period.origin) == "number",
		`KeepBlox: leaderboard "{name}"'s origin is a number`
	)
	const read = board.read
	return {
		-- A board with a period is always given a number: the period it is read for.
		read = function(data: any, at: number?): number?
			return read(data, at or 0)
		end,
		length = period.length,
		origin = period.origin or 0,
	}
end

function Boards.new(
	services: () -> Services.Services,
	storeName: string,
	boards: { [string]: Board },
	options: Options?,
	report: Report.Report,
	timeout: number
): Boards
	const kept: { [string]: Kept } = {}
	for name, board in boards do
		kept[name] = keep(name, board)
	end
	const interval = options and options.interval or 60
	const cacheSeconds = options and options.cache or 60
	const mirrors: { [string]: Mirror } = {}
	const answers: { [string]: Answer } = {}

	const function current(board: Kept): number?
		const length = board.length
		return if length then math.floor((services().clock.time() - board.origin) / length) else nil
	end

	const function ordered(name: string, period: number?): Services.OrderedDataStore
		const suffix = if period then `_{period}` else ""
		return services().dataStores:GetOrderedDataStore(`{storeName}__{name}{suffix}`)
	end

	const function write(key: string, name: string, period: number?, value: number?): boolean
		const bundle = services()
		if bundle.dataStores:GetRequestBudgetForRequestType("OrderedWrite") <= 0 then
			return false
		end
		const store = ordered(name, period)
		const ok, problem = Call.run(bundle.clock, timeout, function()
			if value == nil then
				store:RemoveAsync(key)
			else
				store:SetAsync(key, value)
			end
		end)
		if not ok then
			report(key, `leaderboard {name} not written: {problem}`, "leaderboard")
		end
		return ok
	end

	-- The period a read is of: the one asked for, or the current one; nil for a board without one.
	const function periodOf(name: string, query: Query?): number?
		const found = kept[name]
		assert(found, `KeepBlox: no leaderboard named "{name}"`)
		const asked = query and query.period
		if asked == nil then
			return current(found)
		end
		assert(found.length, `KeepBlox: leaderboard "{name}" has no period`)
		assert(asked == math.floor(asked), "KeepBlox: a period is a whole number")
		return asked
	end

	-- One sorted page, or the answer kept under `id`: fresh within `cache`, and still given, however
	-- old, while the list budget is spent. With nothing kept and no budget it raises.
	const function sorted(id: string, read: () -> Services.SortedPages): { Entry }
		const bundle = services()
		const cached = answers[id]
		if cached and bundle.clock.now() - cached.at < cacheSeconds then
			return table.clone(cached.entries)
		end
		if bundle.dataStores:GetRequestBudgetForRequestType("OrderedList") <= 0 then
			assert(cached, "KeepBlox: the ordered list budget is spent")
			return table.clone(cached.entries)
		end
		const entries: { Entry } = {}
		for _, entry in read():GetCurrentPage() do
			table.insert(entries, { key = entry.key, value = entry.value })
		end
		answers[id] = { at = bundle.clock.now(), entries = entries }
		return table.clone(entries)
	end

	return {
		stored = function(_: Boards, key: string, data: any, final: boolean)
			const clock = services().clock
			const mirror = mirrors[key] or { values = {}, periods = {}, at = -math.huge }
			mirrors[key] = mirror
			if not final and clock.now() - mirror.at < interval then
				return
			end
			mirror.at = clock.now()
			clock.spawn(function()
				for name, spec in kept do
					const period = current(spec)
					const ok, raw = pcall(spec.read, data, period)
					if not ok then
						report(key, `leaderboard {name} failed: {raw}`, "leaderboard")
						continue
					end
					const value = if type(raw) == "number" and raw == raw then math.floor(raw) else nil
					-- A new period's store holds nothing for this key yet, whatever the last one held.
					const previous = if mirror.periods[name] == period then mirror.values[name] else nil
					if value ~= previous and write(key, name, period, value) then
						mirror.values[name] = value
						mirror.periods[name] = period
					end
				end
				if final then
					mirrors[key] = nil
				end
			end)
		end,
		top = function(_: Boards, name: string, query: Query?): { Entry }
			const period = periodOf(name, query)
			const count = math.clamp(query and query.count or 10, 1, 100)
			const ascending = query ~= nil and query.ascending == true
			return sorted(`{name}/{period}/{count}/{ascending}`, function(): Services.SortedPages
				return ordered(name, period):GetSortedAsync(ascending, count)
			end)
		end,
		above = function(_: Boards, name: string, value: number, query: Query?): Entry?
			const period = periodOf(name, query)
			const least = math.floor(value) + 1
			const id = `{name}/{period}/above/{least}`
			-- Each value asked about is its own answer: those past their time are let go, so a long
			-- server life of changing values does not pile them up.
			const now = services().clock.now()
			for other, answer in answers do
				if other ~= id and string.find(other, "/above/", 1, true) and now - answer.at >= cacheSeconds then
					answers[other] = nil
				end
			end
			return sorted(id, function(): Services.SortedPages
				return ordered(name, period):GetSortedAsync(true, 1, least)
			end)[1]
		end,
		period = function(_: Boards, name: string): number?
			return periodOf(name, nil)
		end,
	}
end

return Boards
