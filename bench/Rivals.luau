--!strict
--- Runs every scenario against one library and prints its table (Markdown), the worst of each metric
--- over seeds 1..N. The rivals must be downloaded first (`luneblox run bench/download`).
---
---     luneblox run bench/Rivals [seeds] [library]
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const NaiveAdapter = require("@sim/NaiveAdapter")
const ProfileStoreAdapter = require("@sim/ProfileStoreAdapter")
const Scenarios = require("@sim/Scenarios")
const process = require("@lune/process")

const ORDER = { "rejoin", "handoff", "crash", "partitioned", "thirdRequester", "shutdown", "outage", "poison", "soup" }

-- Rival adapters read their library when required, so only the one asked for is loaded.
const LIBRARIES: { [string]: () -> any } = {
	KeepBlox = function(): any
		return KeepBloxAdapter.default
	end,
	ProfileStore = function(): any
		return ProfileStoreAdapter
	end,
	Naive = function(): any
		return NaiveAdapter
	end,
	ProfileService = function(): any
		return require("./adapters/ProfileServiceAdapter")
	end,
	Lapis = function(): any
		return require("./adapters/LapisAdapter")
	end,
	DocumentService = function(): any
		return require("./adapters/DocumentServiceAdapter")
	end,
	DataStore2 = function(): any
		return require("./adapters/DataStore2Adapter")
	end,
	Suphi = function(): any
		return require("./adapters/SuphiAdapter")
	end,
}

const seeds = tonumber(process.args[1]) or 20
const pick = LIBRARIES[process.args[2] or "KeepBlox"]
assert(pick, `the library is one of: KeepBlox, ProfileStore, Naive, ProfileService`)
const adapter = pick()

print(`{adapter.name}, seeds 1-{seeds}, worst case per scenario:\n`)
print(
	"| Scenario | Progress lost (steps) | Stale owner (s) | Slowest open (s) | Failed opens | Shutdown (s) | Violations |"
)
print("|---|---|---|---|---|---|---|")
for _, name in ORDER do
	const soak = Scenarios.soak(Scenarios.byName[name], adapter, seeds)
	const m = soak.metrics
	const kinds: { [string]: number } = {}
	for _, violation in soak.violations do
		kinds[violation.invariant] = (kinds[violation.invariant] or 0) + 1
	end
	const listed = {}
	for kind, total in kinds do
		table.insert(listed, `{kind} x{total}`)
	end
	table.sort(listed)
	print(
		`| {name} | {m.maxProgressLost} | {string.format("%.1f", m.maxStaleSeconds)} | {string.format(
			"%.1f",
			m.maxOpenSeconds
		)} | {m.failedOpens} of {m.opens + m.failedOpens} | {if soak.maxShutdownSeconds > 0
			then string.format("%.1f", soak.maxShutdownSeconds)
			else "-"} | {if #listed == 0 then "none" else table.concat(listed, ", ")} |`
	)
	if #soak.failures > 0 then
		print(`  thread failures ({#soak.failures}): {soak.failures[1]}`)
	end
end
