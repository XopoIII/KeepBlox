--!strict
--- Mutants of the edit snapshots of large profiles (Snapshots, Delta) and of the hand-over's reused beat
--- verdict (Lease.recent), kept apart from tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/Snapshots.luau",
		from = "\t\t\tconst against = base(session)\n",
		to = "\t\t\tconst against = nil :: Types.Base?\n",
		breaks = "a large profile loses about one beat of play to a crash, not a renewal",
	},
	{
		file = "src/Snapshots.luau",
		from = 'elseif type(edits) ~= "table" or snapshot.b ~= Delta.fingerprint(stored) then',
		to = 'elseif type(edits) ~= "table" then',
		breaks = "edits made against other data than the record's are not used",
	},
	{
		file = "src/Lease.luau",
		from = "x = replace(entry.x, taken.edits),",
		to = "x = entry.x,",
		breaks = "a large profile's edits reach the beat",
	},
	{
		file = "src/Delta.luau",
		from = "\tfor index = size + added - count + 1, size do\n\t\tlist[index] = nil\n\tend\n",
		to = "\n",
		breaks = "an item taken from a list is gone after the edits",
	},
	{
		file = "src/Delta.luau",
		from = "table.move(items, 1, added, at, list)",
		to = "table.move(items, 1, added, at + 1, list)",
		breaks = "an item put into a list lands where it was put",
	},
	{
		file = "src/Delta.luau",
		from = "\tif #base > 0 and #now > 0 then\n\t\tlists(base, now, path, edits)\n\t\treturn\n\tend\n",
		to = "\n",
		breaks = "things added and removed between writes come back after a crash",
	},
	{
		file = "src/Claim.luau",
		from = "then Lease.recent(context, current.beat) or Lease.judge(",
		to = "then Lease.judge(",
		breaks = "a hand-over completes within 3.05 s: a beat just looked at is not looked at again",
	},
	{
		file = "src/Lease.luau",
		from = "return if context.services.clock.now() - lookedAt < 1 then watch.verdict else nil",
		to = "return watch.verdict",
		breaks = "a verdict older than a second is looked at again",
	},
	{
		file = "src/Gate.luau",
		from = "if state.failing > OPEN and (probe or not state.open) then",
		to = "if false then",
		breaks = "a store that is down gets one probe at a time, and keeps the budget for when it is back",
	},
	{
		file = "src/Gate.luau",
		from = "elseif clock.now() >= state.nextProbe and not state.probing then",
		to = "elseif clock.now() >= state.nextProbe then",
		breaks = "a second load is not the probe while one is in flight",
	},
	{
		file = "src/Gate.luau",
		from = "\t\tif state.answered ~= answered then\n\t\t\treturn false\n\t\telseif left < TINY then",
		to = "\t\tif left < TINY then",
		breaks = "the probe that answers lets every waiting load go at once",
	},
	{
		file = "src/Claim.luau",
		from = "\t\tGate.drop(context.services, probe)\n",
		to = "",
		breaks = "a probe that gives up before its call frees the next one",
	},
	{
		file = "src/Claim.luau",
		from = "probe = Gate.wait(context.services, delay, deadline, stopped)",
		to = "probe = Gate.wait(context.services, 0, deadline, stopped)",
		breaks = "a lone failing load keeps its own backoff",
	},
} :: { { file: string, from: string, to: string, breaks: string } }
