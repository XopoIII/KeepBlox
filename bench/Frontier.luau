--!strict
--- KeepBlox's cost against its crash loss, for several `renew` intervals: the one trade-off no library
--- escapes (data store writes an hour x the seconds a crash can lose is about constant).
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
