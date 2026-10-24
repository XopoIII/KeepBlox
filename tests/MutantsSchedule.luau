--!strict
--- Mutants of a schedule (src/Schedule.luau, src/Sweep.luau, src/JobIndex.luau): the claim that keeps a
--- job to one server, the version that lets a game's change win, the index that never finds a job late,
--- the id that keeps a change to once, the drop past `keep` and the budget's reserve. Kept apart from
--- tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/Sweep.luau",
		from = "elseif JobRecord.claimed(record, now) then",
		to = "elseif false then",
		breaks = "a job claimed by one sweep is not taken by another",
	},
	{
		file = "src/Sweep.luau",
		from = "if record.version == version and (outcome",
		to = "if (outcome",
		breaks = "a game's change made while a job runs wins over the handler's answer",
	},
	{
		file = "src/Sweep.luau",
		from = "elseif now - due > context.keep then",
		to = "elseif false then",
		breaks = "a job no sweep finished is dropped past `keep`",
	},
	{
		file = "src/Sweep.luau",
		from = 'if dataStores:GetRequestBudgetForRequestType("StandardWrite") < reserve then',
		to = "if false then",
		breaks = "a sweep leaves the last writes of the budget to saves",
	},
	{
		file = "src/Sweep.luau",
		from = "JobIndex.settle(stores, key, seen, later)",
		to = "JobIndex.settle(stores, key, seen, seen)",
		breaks = "a key found early has its index moved to its job's time",
	},
	{
		file = "src/Sweep.luau",
		from = "\t\tswept.done += 1\n\t\tJobIndex.settle(stores, key, seen, JobIndex.PARKED)\n",
		to = "\t\tswept.done += 1\n",
		breaks = "a done job's index entry is parked",
	},
	{
		file = "src/JobIndex.luau",
		from = "if current ~= nil and current <= due then",
		to = "if current ~= nil and current >= due then",
		breaks = "a game's change never moves the index later",
	},
	{
		file = "src/JobIndex.luau",
		from = 'if JobRecord.classify(value) == "job" then',
		to = "if false then",
		breaks = "a job put while a sweep parks its key is found all the same",
	},
	{
		file = "src/Schedule.luau",
		from = "if Once.seen(record.applied, id) then",
		to = "if false then",
		breaks = "a change tried again after it landed is not applied twice",
	},
	{
		file = "src/Sweep.luau",
		from = 'context.report(key, `a scheduled job\'s handler failed: {tostring(answer)}`, "schedule")',
		to = 'context.report(key, `a scheduled job\'s handler failed: {tostring(answer)}`, "message")',
		breaks = "a handler that throws is reported as a schedule's",
	},
}
