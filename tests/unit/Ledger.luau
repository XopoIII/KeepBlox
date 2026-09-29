--!strict
--- The ledger must catch the breaches it exists for: a spec that only ever sees clean runs proves
--- nothing. A deliberately unsafe library supplies them.
const Ledger = require("@sim/Ledger")
const NaiveAdapter = require("@sim/NaiveAdapter")
const Scenarios = require("@sim/Scenarios")
const Scheduler = require("@fakes/Scheduler")
const Spec = require("../Spec")

const function count(violations: { Ledger.Violation }, invariant: string): number
	local total = 0
	for _, violation in violations do
		if violation.invariant == invariant then
			total += 1
		end
	end
	return total
end

Spec.test("Ledger: two servers saving one key without a lock are caught", function()
	const result = Scenarios.soak(Scenarios.handoff, NaiveAdapter, 5)
	Spec.truthy(count(result.violations, "foreign-write") > 0, "foreign-write reported")
end)

Spec.test("Ledger: a stale session overwriting newer saved progress is caught", function()
	const result = Scenarios.soak(Scenarios.handoff, NaiveAdapter, 10)
	Spec.truthy(count(result.violations, "ack-lost") > 0, "ack-lost reported")
end)

Spec.test("Ledger: a load count that goes down is caught", function()
	const scheduler = Scheduler.new(1)
	const ledger = Ledger.new(scheduler, function(name: string): string
		return `job-{name}`
	end)
	const before = { Data = { n = 1 }, MetaData = { SessionLoadCount = 5, ActiveSession = { 1, "job-A", "g" } } }
	const after = { Data = { n = 2 }, MetaData = { SessionLoadCount = 4, ActiveSession = { 1, "job-A", "g" } } }
	const version = function(value: any): any
		return { id = "v", createdMs = 0, value = value, userIds = {}, metadata = {}, deleted = false }
	end
	Ledger.checkWrite(ledger, scheduler, function(name: string): string
		return `job-{name}`
	end, { store = "S", key = "k", previous = version(before), version = version(after), writer = "A" })
	Spec.equal(#ledger.violations, 1)
	Spec.equal(ledger.violations[1].invariant, "load-count-backwards")
	Spec.equal(ledger.violations[1].detail, "SessionLoadCount went from 5 to 4")
end)

Spec.test("Ledger: the owner's own save is not a foreign write", function()
	const scheduler = Scheduler.new(1)
	const jobOf = function(name: string): string
		return `job-{name}`
	end
	const ledger = Ledger.new(scheduler, jobOf)
	const lock = { 1, "job-A", "g" }
	const version = function(n: number): any
		return {
			id = "v",
			createdMs = 0,
			value = { Data = { n = n }, MetaData = { SessionLoadCount = 1, ActiveSession = lock } },
			userIds = {},
			metadata = {},
			deleted = false,
		}
	end
	Ledger.checkWrite(ledger, scheduler, jobOf, {
		store = "S",
		key = "k",
		previous = version(1),
		version = version(2),
		writer = "A",
	})
	Spec.equal(ledger.violations, {})
	Ledger.checkWrite(ledger, scheduler, jobOf, {
		store = "S",
		key = "k",
		previous = version(2),
		version = version(3),
		writer = "B",
	})
	Spec.equal(#ledger.violations, 1)
	Spec.equal(ledger.violations[1].detail, "B changed Data while the lock was held by job-A")
end)

return nil
