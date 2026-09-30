--!strict
--- KeepBlox's MemoryStore beat against how fast a crashed owner is taken over: a dead owner is known
--- after its beat stands still for two beats, so a shorter `heartbeat` takes over sooner and costs more
--- MemoryStore units. Every story runs at each setting, so a faster beat that breaks an invariant shows.
---
---     luneblox run bench/Heartbeat [seeds]
const Cost = require("./Cost")
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const Scenarios = require("@sim/Scenarios")
const process = require("@lune/process")

const seeds = tonumber(process.args[1]) or 10

const SETTINGS: { { heartbeat: number, renewFallback: number } } = {
	{ heartbeat = 4, renewFallback = 30 },
	{ heartbeat = 4, renewFallback = 10 },
	{ heartbeat = 2, renewFallback = 10 },
}

print(
	"| heartbeat (s) | renewFallback (s) | Crash: slowest open (s) | Crash: progress lost (steps) | Hand-over: slowest open (s) | MemoryStore units per player-hour | Reads + writes per player-hour | Violations |"
)
print("|---|---|---|---|---|---|---|---|")
for _, setting in SETTINGS do
	const adapter = KeepBloxAdapter.with({ heartbeat = setting.heartbeat, renewFallback = setting.renewFallback })
	const hour = Cost.hour(adapter, 1)
	const crash = Scenarios.soak(Scenarios.crash, adapter, seeds)
	const handoff = Scenarios.soak(Scenarios.handoff, adapter, seeds)
	local violations = hour.violations
	for _, scenario in Scenarios.byName do
		violations += #Scenarios.soak(scenario, adapter, seeds).violations
	end
	const requests = (hour.perPlayerHour.StandardRead or 0) + (hour.perPlayerHour.StandardWrite or 0)
	print(
		`| {setting.heartbeat} | {setting.renewFallback} | {string.format("%.1f", crash.metrics.maxOpenSeconds)} | {crash.metrics.maxProgressLost} | {string.format(
			"%.1f",
			handoff.metrics.maxOpenSeconds
		)} | {string.format("%.0f", hour.memory)} | {string.format("%.1f", requests)} | {violations} |`
	)
end
