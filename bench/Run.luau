--!strict
--- What saving a profile costs a frame, against fixed budgets (guarantee 13: saving never spikes a
--- frame).
---
--- A write copies the profile at once (`Record.copy`), then checks and encodes the copy
--- (`Validate.check`), letting a frame pass every 2 ms of work (`Session.slicer`). So the longest
--- stretch any one frame pays is the copy plus one slice, whatever the profile's size. That stretch
--- has the budget. The total CPU time is reported beside it. Measured on LuneBlox, which runs the Luau
--- and fast flags Roblox runs; budgets leave room for slower CI machines.
---
---     luneblox run bench/Run
const Record = require("../src/Record")
const Runtime = require("../tests/Runtime")
const Validate = require("../src/Validate")
const process = require("@lune/process")

type Case = { name: string, items: number, budget: number }

-- The slice the library uses (src/Session.luau).
const SLICE_SECONDS = 0.002

-- A typical profile: currencies, settings and an inventory of items with a few fields each.
const function profile(items: number): any
	const inventory = table.create(items)
	for index = 1, items do
		inventory[index] = {
			id = `item_{index}`,
			name = `Blade of the {index}th dawn`,
			level = index % 50,
			power = index * 1.25,
			tags = { "weapon", "rare" },
			equipped = index % 7 == 0,
		}
	end
	return {
		coins = 12_345,
		gems = 67,
		settings = { music = 0.4, sound = 0.8, locale = "en-us" },
		inventory = inventory,
	}
end

const function median(samples: { number }): number
	table.sort(samples)
	return samples[math.ceil(#samples / 2)]
end

-- One write's work: returns (copy ms, longest slice ms, total ms).
const function once(data: any): (number, number, number)
	const started = os.clock()
	const snapshot = Record.copy(data)
	const copied = os.clock()
	local sliceStarted = copied
	local longest = 0
	Validate.check(snapshot, "Data", nil, function()
		const now = os.clock()
		if now - sliceStarted >= SLICE_SECONDS then
			longest = math.max(longest, now - sliceStarted)
			sliceStarted = now
		end
	end)
	const finished = os.clock()
	longest = math.max(longest, finished - sliceStarted)
	return (copied - started) * 1000, longest * 1000, (finished - started) * 1000
end

const CASES: { Case } = {
	{ name = "10 KB", items = 70, budget = 1.5 },
	{ name = "100 KB", items = 700, budget = 6 },
	{ name = "1 MB", items = 7000, budget = 16 },
}

Runtime.notice()
local failed = false
print(
	"| Profile | Size (bytes) | Copy (ms) | Longest slice (ms) | Longest stretch (ms) | Budget (ms) | Total CPU (ms) |"
)
print("|---|---|---|---|---|---|---|")
for _, case in CASES do
	const data = profile(case.items)
	const encoded = assert(Validate.check(data, "Data"), "the benchmark profile is valid")
	const runs = if case.items > 1000 then 21 else 101
	const copies, slices, totals = {}, {}, {}
	for index = 1, runs do
		copies[index], slices[index], totals[index] = once(data)
	end
	const copy, slice = median(copies), median(slices)
	const stretch = copy + slice
	const over = stretch > case.budget
	failed = failed or over
	print(
		string.format(
			"| %s | %d | %.3f | %.3f | %.3f | %.1f%s | %.3f |",
			case.name,
			encoded.size,
			copy,
			slice,
			stretch,
			case.budget,
			if over then " OVER" else "",
			median(totals)
		)
	)
end
if failed then
	print("\nA benchmark is over its budget.")
	process.exit(1)
end
