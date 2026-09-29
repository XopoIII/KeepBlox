--!strict
--- Injected faults and latency for the fake services.
---
--- A rule matches a call by operation, key and server (each optional: nil matches all), and fires a
--- number of times (nil: forever). It either throws, or hangs the call for good. A rule can fire
--- `after` the write commits: the docs warn that a failed write "does not always guarantee that the
--- backend write did not occur" (error-codes-and-limits), and the library must survive exactly that.
const Prng = require("./Prng")

export type Rule = {
	op: string?,
	key: string?,
	server: string?,
	--> The error to throw. Omit it with `hang = true`.
	error: string?,
	--> The call never returns (a request lost in flight).
	hang: boolean?,
	--> Fire after the write has committed, not before it.
	after: boolean?,
	--> How many more times the rule fires; nil for every matching call.
	times: number?,
}

export type Faults = {
	--> Latency of one call, in seconds, drawn uniformly from [min, max].
	latency: { min: number, max: number },
	--> Adds a rule. Rules are checked in the order added; the first match fires.
	add: (self: Faults, rule: Rule) -> (),
	--> Removes every rule.
	clear: (self: Faults) -> (),
	--> The rule that fires for this call and phase, consuming one of its `times`, or nil.
	match: (self: Faults, op: string, key: string?, server: string, after: boolean) -> Rule?,
	--> One latency sample.
	sample: (self: Faults) -> number,
}

const Faults = {}

function Faults.new(random: Prng.Prng): Faults
	local rules: { Rule } = {}

	return {
		latency = { min = 0.05, max = 0.25 },

		add = function(_: Faults, rule: Rule)
			assert(rule.error or rule.hang, "a fault rule needs an error or hang = true")
			table.insert(rules, table.clone(rule))
		end,

		clear = function(_: Faults)
			rules = {}
		end,

		match = function(_: Faults, op: string, key: string?, server: string, after: boolean): Rule?
			for index, rule in rules do
				if
					(rule.op == nil or rule.op == op)
					and (rule.key == nil or rule.key == key)
					and (rule.server == nil or rule.server == server)
					and (rule.after == true) == after
				then
					if rule.times then
						rule.times -= 1
						if rule.times <= 0 then
							table.remove(rules, index)
						end
					end
					return rule
				end
			end
			return nil
		end,

		sample = function(self: Faults): number
			const range = self.latency
			return range.min + (range.max - range.min) * random:number()
		end,
	}
end

return Faults
