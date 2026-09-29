--!strict
--- KeepBlox in every scenario, held to the guarantees and to bounds that beat the ProfileStore
--- baseline (tests/reference/BASELINE.md) on each weak spot.
const KeepBlox = require("@keepblox")
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const Scenarios = require("@sim/Scenarios")
const Spec = require("../Spec")

const SEEDS = 5
const RENEW, DEATH, BACKOFF = KeepBlox.defaults.renew, KeepBlox.defaults.death, KeepBlox.defaults.backoffMax

const function soak(name: string): Scenarios.Soak
	const result = Scenarios.soak(Scenarios.byName[name], KeepBloxAdapter.default, SEEDS)
	Spec.equal(result.violations, {}, `{name}: violations`)
	Spec.equal(result.failures, {}, `{name}: thread failures`)
	return result
end

Spec.test("KeepBlox: hand-overs lose nothing and leave no stale owner", function()
	for _, name in { "rejoin", "handoff", "thirdRequester", "outage" } do
		const metrics = soak(name).metrics
		Spec.equal(metrics.maxProgressLost, 0, `{name}: progress lost`)
		Spec.equal(metrics.maxStaleSeconds, 0, `{name}: stale seconds`)
		Spec.truthy(metrics.maxOpenSeconds < 10, `{name}: open took {metrics.maxOpenSeconds} s`)
	end
end)

Spec.test("KeepBlox: a crash loses at most one renewal interval (baseline: 287 s)", function()
	const metrics = soak("crash").metrics
	Spec.truthy(metrics.maxProgressLost <= RENEW, `lost {metrics.maxProgressLost} steps`)
	-- The dead owner's lease is watched for `death` seconds, then taken at the next poll.
	Spec.truthy(metrics.maxOpenSeconds <= DEATH + BACKOFF + 1, `open took {metrics.maxOpenSeconds} s`)
	Spec.truthy(metrics.maxOpenSeconds < 46, "faster than the baseline's 46 s")
end)

Spec.test("KeepBlox: an owner cut off from messaging hands over at its next renewal (baseline: 244 s stale)", function()
	const metrics = soak("partitioned").metrics
	Spec.equal(metrics.maxStaleSeconds, 0)
	Spec.equal(metrics.maxProgressLost, 0)
	Spec.truthy(metrics.maxOpenSeconds <= RENEW + BACKOFF + 1, `open took {metrics.maxOpenSeconds} s`)
end)

Spec.test("KeepBlox: bad data never blocks the release (baseline: the next server waits 46 s)", function()
	const metrics = soak("poison").metrics
	Spec.truthy(metrics.maxOpenSeconds < 5, `the next server waited {metrics.maxOpenSeconds} s`)
end)

Spec.test("KeepBlox: shutdown with 50 players on a slow data store fits the deadline", function()
	const result = soak("shutdown")
	Spec.equal(result.missedShutdowns, 0)
	Spec.truthy(result.maxShutdownSeconds < 10, `shutdown took {result.maxShutdownSeconds} s`)
	Spec.equal(result.metrics.maxProgressLost, 0)
end)

Spec.test("KeepBlox: random play with crashes keeps every invariant", function()
	const metrics = soak("soup").metrics
	Spec.truthy(metrics.maxProgressLost <= RENEW, `lost {metrics.maxProgressLost} steps`)
end)

return nil
