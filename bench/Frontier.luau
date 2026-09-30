--!strict
--- KeepBlox's cost against its crash loss, for several `renew` intervals. A library with only the data
--- store cannot escape the trade-off: data store writes an hour x the seconds a crash can lose is about
--- constant. KeepBlox's heartbeat snapshots (see Snapshots) step out of it: the loss stays about one beat
--- at every `renew` (2026-09-30, 10 seeds: 3-4 steps from 15 s to 300 s), so `renew` sets only the cost.
--- A loss that grows with `renew` here means the snapshots stopped covering the crash.
---
---     luneblox run bench/Frontier [seeds]
const Cost = require("./Cost")
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const Scenarios = require("@sim/Scenarios")
const process = require("@lune/process")

const seeds = tonumber(process.args[1]) or 10

print(
	"| renew (s) | Reads + writes per player-hour | Crash: progress lost (steps) | Crash: slowest open (s) | Violations |"
)
print("|---|---|---|---|---|")
for _, renew in { 15, 30, 60, 120, 300 } do
	const adapter = KeepBloxAdapter.with({ renew = renew, death = 2 * renew + 5 })
	const hour = Cost.hour(adapter, 1)
	const crash = Scenarios.soak(Scenarios.crash, adapter, seeds)
	local violations = #crash.violations
	for _, name in { "rejoin", "handoff", "partitioned", "soup" } do
		violations += #Scenarios.soak(Scenarios.byName[name], adapter, seeds).violations
	end
	const requests = (hour.perPlayerHour.StandardRead or 0) + (hour.perPlayerHour.StandardWrite or 0)
	print(
		`| {renew} | {string.format("%.1f", requests)} | {crash.metrics.maxProgressLost} | {string.format(
			"%.1f",
			crash.metrics.maxOpenSeconds
		)} | {violations} |`
	)
end
