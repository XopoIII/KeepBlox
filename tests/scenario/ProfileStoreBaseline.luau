--!strict
--- The baseline: what the unmodified ProfileStore does in every scenario, stated as exact bounds.
---
--- It keeps the data invariants (no acknowledged save lost, one writer, load count never backwards),
--- and it shows the weak spots the plan names (.claude/plan/01-findings.md), measured:
--- - a crash loses up to the 300 s autosave window;
--- - a dead owner is taken over only after about 45 s;
--- - an owner cut off from MessagingService stays active, with stale data, for minutes;
--- - one bad string blocks every later save and the release.
--- KeepBlox's own scenario specs must beat each of these numbers; see tests/reference/BASELINE.md.
const ProfileStoreAdapter = require("@sim/ProfileStoreAdapter")
const Scenarios = require("@sim/Scenarios")
const Spec = require("../Spec")

const SEEDS = 5

const function soak(name: string): Scenarios.Soak
	const result = Scenarios.soak(Scenarios.byName[name], ProfileStoreAdapter, SEEDS)
	Spec.equal(result.violations, {}, `{name}: violations`)
	Spec.equal(result.failures, {}, `{name}: thread failures`)
	return result
end

Spec.test("Baseline ProfileStore: leaving and rejoining elsewhere loses nothing", function()
	for _, name in { "rejoin", "handoff" } do
		const result = soak(name)
		Spec.equal(result.metrics.maxProgressLost, 0, `{name}: progress lost`)
		Spec.equal(result.metrics.maxStaleSeconds, 0, `{name}: stale seconds`)
		Spec.truthy(result.metrics.maxOpenSeconds < 10, `{name}: open took {result.metrics.maxOpenSeconds} s`)
	end
end)

Spec.test("Baseline ProfileStore: a crash loses the progress since the last autosave", function()
	const metrics = soak("crash").metrics
	-- Crashes land 30-290 s in, before the first 300 s autosave, so the whole session is lost.
	Spec.truthy(metrics.maxProgressLost >= 100 and metrics.maxProgressLost <= 300, `lost {metrics.maxProgressLost}`)
	-- The dead owner's lock is stolen after the first request, a 5 s wait and 40 s of retries.
	Spec.truthy(metrics.maxOpenSeconds >= 40 and metrics.maxOpenSeconds < 50, `open {metrics.maxOpenSeconds} s`)
end)

Spec.test("Baseline ProfileStore: an owner that misses the message keeps stale data active", function()
	const metrics = soak("partitioned").metrics
	Spec.truthy(metrics.maxStaleSeconds > 60, `stale for {metrics.maxStaleSeconds} s`)
	Spec.truthy(metrics.maxProgressLost > 0, `lost {metrics.maxProgressLost}`)
end)

Spec.test("Baseline ProfileStore: a bad string blocks every later save", function()
	const metrics = soak("poison").metrics
	Spec.truthy(metrics.maxProgressLost >= 100, `lost {metrics.maxProgressLost}`)
	Spec.truthy(metrics.maxOpenSeconds >= 40, `the next server waited {metrics.maxOpenSeconds} s`)
end)

Spec.test("Baseline ProfileStore: of three requesters, the older waiting one gets nothing", function()
	const result = soak("thirdRequester")
	Spec.equal(result.metrics.failedOpens, SEEDS)
	Spec.equal(result.metrics.maxProgressLost, 0)
end)

Spec.test("Baseline ProfileStore: shutdown and a two-minute outage lose nothing", function()
	const shutdown = soak("shutdown")
	Spec.equal(shutdown.missedShutdowns, 0)
	Spec.truthy(shutdown.maxShutdownSeconds < 30, `shutdown took {shutdown.maxShutdownSeconds} s`)
	Spec.equal(soak("outage").metrics.maxProgressLost, 0)
end)

Spec.test("Baseline ProfileStore: random play with crashes keeps every invariant", function()
	soak("soup")
end)

return nil
