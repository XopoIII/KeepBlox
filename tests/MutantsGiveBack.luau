--!strict
--- Mutants of what a load gives back when it will not keep the key it claimed: because its player
--- left or its server is closing as the claim lands, because it failed or threw past the claim, or
--- because the shutdown began before its session was listed (0.6.9, issues 33 and 34). Kept apart
--- from tests/Mutants.luau, which lists them with the rest.
---
--- Left out as equivalent: the reason the session of a load that found its store closing is released
--- with. No game ever saw that profile, so nobody hears it.

return {
	{
		file = "src/Claim.luau",
		from = "LetGo.undo(context, key, outcome)",
		to = "LetGo.giveBack(context, key, outcome.loadCount)",
		breaks = "a load that gives up as its takeover lands stores the dead owner's last beat before it frees the key",
	},
	{
		file = "src/LetGo.luau",
		from = " and Record.ours(taken.record.MetaData).trade == nil",
		to = "",
		breaks = "a key given back with an unfinished trade costs no read of its last owner's beat",
	},
	{
		file = "src/LetGo.luau",
		from = "const ok, problem, unstored = pcall(Recover.run, context, key, taken.loadCount, taken.record, previous)",
		to = "const ok, problem, unstored = true, Recover.run(context, key, taken.loadCount, taken.record, previous)",
		breaks = "a last beat this server cannot store does not keep the key from being given back",
	},
	{
		file = "src/LetGo.luau",
		from = "context.report(key, `the previous owner's last beat could not be stored: {problem}`)",
		to = "",
		breaks = "a last beat that could not be stored before the key was given back is reported",
	},
	{
		file = "src/LetGo.luau",
		from = "context.report(key, `a key its load gave up was not given back: {err}`)",
		to = "",
		breaks = "a give-back the data store refused is reported",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\tif clock.now() + delay >= deadline then\n\t\t\treturn\n\t\tend\n\t\tclock.wait(delay)\n",
		to = "\t\tif true then\n\t\t\treturn\n\t\tend\n\t\tclock.wait(delay)\n",
		breaks = "a give-back the data store refused is tried again",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\tif clock.now() + delay >= deadline then\n\t\t\treturn\n\t\tend\n\t\tclock.wait(delay)\n",
		to = "\t\tclock.wait(delay)\n",
		breaks = "a give-back the data store never takes ends at the load's deadline",
	},
	{
		file = "src/LetGo.luau",
		from = "\tconst deadline = context.deadline or clock.now() + config.loadTimeout\n\tlocal delay = config.backoffMin\n\twhile true do\n",
		to = "\tconst deadline = clock.now() + config.loadTimeout\n\tlocal delay = config.backoffMin\n\twhile true do\n",
		breaks = "a give-back's tries count against the load's own deadline, not one of their own",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\tclock.wait(delay)\n\t\tdelay = math.min(delay * 2, config.backoffMax)\n",
		to = "\t\tclock.wait(delay)\n\t\tdelay = delay * 2\n",
		breaks = "a give-back is tried again with the load's backoff, capped",
	},
	{
		file = "src/Open.luau",
		from = "\t\tLetGo.undo(context, key, taken)\n",
		to = "\t\tLetGo.giveBack(context, key, taken.loadCount)\n",
		breaks = "a load that throws before the dead owner's last beat was stored stores it before it frees the key",
	},
	{
		file = "src/Open.luau",
		from = "\t\tdrop()\n\t\terror(answer, 0)",
		to = "\t\terror(answer, 0)",
		breaks = "a load that throws past its claim gives the key back",
	},
	{
		file = "src/Open.luau",
		from = "\t\tdrop()\n\t\tstate.opening[key] = nil\n",
		to = "\t\tstate.opening[key] = nil\n",
		breaks = "a load that fails past its claim (a migration, a trade not settled) gives the key back",
	},
	{
		file = "src/Open.luau",
		from = "\tif orphaned or state.closing() then\n",
		to = "\tif orphaned then\n",
		breaks = "a load whose claim had landed when the shutdown began releases the session nobody else will",
	},
	{
		file = "src/Open.luau",
		from = 'reason = if orphaned then "cancelled" else "closing"',
		to = 'reason = "cancelled"',
		breaks = 'a load that found its store closing answers "closing"',
	},
	{
		file = "src/Enter.luau",
		from = "\t\t\ttaken.previous = nil\n\t\tend\n\telse\n",
		to = "\t\tend\n\telse\n",
		breaks = "a load undone after it stored the dead owner's last beat does not read and store it again",
	},
	{
		file = "src/Recover.luau",
		from = "\tconst data = if snapshot.p == nil\n\t\tthen snapshot.d\n\t\telse Snapshots.data(snapshot, Codec.unpack(context.services.codec, record.Data))\n",
		to = "\tconst data = Snapshots.data(snapshot, Codec.unpack(context.services.codec, record.Data))\n",
		breaks = "a whole last beat is stored though this server cannot unpack the record it replaces",
	},
}
