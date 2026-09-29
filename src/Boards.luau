--!strict
--- Leaderboards beside the profiles: chosen numbers mirrored into OrderedDataStores, and read back
--- sorted.
---
---     const store = KeepBlox.store("Profiles", {
---         template = { coins = 0, wins = 0 },
---         leaderboards = {
---             coins = function(data) return data.coins end,
---             wins = function(data) return data.wins end,
---         },
---     })
---     const top = store:leaderboard("coins", { count = 10 })  -- { {key = "u_1", value = 900}, ... }
---
--- A board is the ordered data store "<store>__<board>", keyed by profile key. After a save stores a
--- profile, each board's value is written if it changed, at most once per `interval` seconds per
--- profile, and always on the release. It is a mirror, written after the save and not with it: the
--- profile is the truth, and a board can trail it by up to `interval`. A value is an integer (it is
--- floored); nil removes the key from the board.
---
--- Ordered writes have their own small budget (30 + 5 per player a minute) and reads a smaller one
--- (5 + 2 per player): a write waits for the next save when that budget is spent, and `leaderboard`
--- keeps each answer for `cache` seconds.
const Call = require("./Call")
const Services = require("./Services")

export type Board = (data: any) -> number?

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
}

export type Boards = {
	--> Called after a save stored `data` for `key`; `final` on the release.
	stored: (self: Boards, key: string, data: any, final: boolean) -> (),
	top: (self: Boards, name: string, query: Query?) -> { Entry },
}

type Mirror = { values: { [string]: number? }, at: number }

const Boards = {}

function Boards.new(
	services: () -> Services.Services,
	storeName: string,
	boards: { [string]: Board },
	options: Options?,
	report: (key: string, message: string) -> (),
	timeout: number
): Boards
	for name, read in boards do
		assert(type(name) == "string" and type(read) == "function", "KeepBlox: a leaderboard is a name and a function")
	end
	const interval = options and options.interval or 60
	const cacheSeconds = options and options.cache or 60
	const mirrors: { [string]: Mirror } = {}
	const answers: { [string]: { at: number, entries: { Entry } } } = {}

	const function ordered(name: string): Services.OrderedDataStore
		return services().dataStores:GetOrderedDataStore(`{storeName}__{name}`)
	end

	const function write(key: string, name: string, value: number?): boolean
		const bundle = services()
		if bundle.dataStores:GetRequestBudgetForRequestType("OrderedWrite") <= 0 then
			return false
		end
		const store = ordered(name)
		const ok, problem = Call.run(bundle.clock, timeout, function()
			if value == nil then
				store:RemoveAsync(key)
			else
				store:SetAsync(key, value)
			end
		end)
		if not ok then
			report(key, `leaderboard {name} not written: {problem}`)
		end
		return ok
	end

	return {
		stored = function(_: Boards, key: string, data: any, final: boolean)
			const clock = services().clock
			const mirror = mirrors[key] or { values = {}, at = -math.huge }
			mirrors[key] = mirror
			if not final and clock.now() - mirror.at < interval then
				return
			end
			mirror.at = clock.now()
			clock.spawn(function()
				for name, read in boards do
					const ok, raw = pcall(read, data)
					if not ok then
						report(key, `leaderboard {name} failed: {raw}`)
						continue
					end
					const value = if type(raw) == "number" and raw == raw then math.floor(raw) else nil
					if value ~= mirror.values[name] and write(key, name, value) then
						mirror.values[name] = value
					end
				end
				if final then
					mirrors[key] = nil
				end
			end)
		end,
		top = function(_: Boards, name: string, query: Query?): { Entry }
			assert(boards[name], `KeepBlox: no leaderboard named "{name}"`)
			const count = math.clamp(query and query.count or 10, 1, 100)
			const ascending = query ~= nil and query.ascending == true
			const id = `{name}/{count}/{ascending}`
			const clock = services().clock
			const cached = answers[id]
			if cached and clock.now() - cached.at < cacheSeconds then
				return table.clone(cached.entries)
			end
			const page = ordered(name):GetSortedAsync(ascending, count):GetCurrentPage()
			const entries: { Entry } = {}
			for _, entry in page do
				table.insert(entries, { key = entry.key, value = entry.value })
			end
			answers[id] = { at = clock.now(), entries = entries }
			return table.clone(entries)
		end,
	}
end

return Boards
