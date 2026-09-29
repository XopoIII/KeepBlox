--!strict
--- Prints the scenario table for a library as Markdown, the worst of each metric over seeds 1..N.
---
---     luneblox run tests/Baseline [seeds] [adapter]
---
--- It is how the numbers in tests/reference/BASELINE.md were made; re-run it to refresh them.
const CompatAdapter = require("@sim/CompatAdapter")
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const NaiveAdapter = require("@sim/NaiveAdapter")
const ProfileStoreAdapter = require("@sim/ProfileStoreAdapter")
const Runtime = require("./Runtime")
const Scenarios = require("@sim/Scenarios")
const process = require("@lune/process")

const ORDER = { "rejoin", "handoff", "crash", "partitioned", "thirdRequester", "shutdown", "outage", "poison", "soup" }
const ADAPTERS = {
	ProfileStore = ProfileStoreAdapter,
	Naive = NaiveAdapter,
	KeepBlox = KeepBloxAdapter.default,
	Compat = CompatAdapter,
}

Runtime.notice()
const seeds = tonumber(process.args[1]) or 20
const adapter = ADAPTERS[process.args[2] or "ProfileStore"]
assert(adapter, "the adapter is ProfileStore, KeepBlox or Naive")

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
	assert(#soak.failures == 0, `{name}: thread failures: {soak.failures[1]}`)
end
