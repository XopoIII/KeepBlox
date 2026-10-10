--!strict
--- Mutants of the loose ends of giving a key back (0.6.10, issues 36 and 37): the note of a dead
--- owner's last beat nobody could store, the freeing of a key held with no session, the tries to let
--- go of a key a load may have taken, a `cancel` that throws, and a release nobody holds that throws.
--- Kept apart from tests/Mutants.luau, which lists them with the rest.
---
--- Left out as equivalent: `owed = if release then session.owed else nil` in Session's write without
--- its condition. Only the release of a session nobody played on sets `session.owed`, right before it.

return {
	{
		file = "src/Owed.luau",
		from = "\t\tor note.at ~= meta.SessionLoadCount\n",
		to = "",
		breaks = "a note is void once any session has loaded the key since it was left",
	},
	{
		file = "src/Owed.luau",
		from = "\tours.owed = nil\n",
		to = "",
		breaks = "a claim uses the note up",
	},
	{
		file = "src/Owed.luau",
		from = "\t\tif Record.isHere(before, identity) then\n\t\t\treturn nil\n\t\tend\n",
		to = "",
		breaks = "a server claiming the key it already holds has no previous owner",
	},
	{
		file = "src/Lock.luau",
		from = "\t\tOwed.leave(meta, payload.owed)\n",
		to = "",
		breaks = "a give-back that owes a beat leaves the note",
	},
	{
		file = "src/Lock.luau",
		from = "if loadCount then meta.SessionLoadCount == loadCount else",
		to = "if loadCount then true else",
		breaks = "a key is disowned by load count only at that load count",
	},
	{
		file = "src/LetGo.luau",
		from = "owed = if not ok or unstored then previous else nil",
		to = "owed = if not ok then previous else nil",
		breaks = "a beat the load could not store, without throwing, is left to the next load",
	},
	{
		file = "src/LetGo.luau",
		from = "owed = if not ok or unstored then previous else nil",
		to = "owed = if unstored then previous else nil",
		breaks = "a beat whose storing threw is left to the next load",
	},
	{
		file = "src/Recover.luau",
		from = "\t\treturn record, not answered\n",
		to = "\t\treturn record, false\n",
		breaks = "a beat MemoryStore gave no answer about is still owed",
	},
	{
		file = "src/Recover.luau",
		from = "\t\treturn record, not ok\n",
		to = "\t\treturn record, false\n",
		breaks = "a beat the data store took no write of is still owed",
	},
	{
		file = "src/Lease.luau",
		from = "\t\treturn nil, entry ~= false\n",
		to = "\t\treturn nil, false\n",
		breaks = "a server that left no newer snapshot is owed nothing: no note is left",
	},
	{
		file = "src/Enter.luau",
		from = "taken.record = Record.copy(record)",
		to = "taken.record = record",
		breaks = "a beat tried again by the undoing is applied to the data as claimed, not as migrated",
	},
	{
		file = "src/Enter.luau",
		from = "\telse\n\t\t-- A profile in a trade has no snapshot (see Lease): nothing of its last owner is left to store.\n\t\ttaken.previous = nil\n",
		to = "\telse\n",
		breaks = "a key with an unfinished trade owes nothing of its last owner",
	},
	{
		file = "src/Open.luau",
		from = "\t\tsession.owed = taken.previous\n",
		to = "",
		breaks = "the release of a session nobody played on leaves the note of a beat it could not store",
	},
	{
		file = "src/Versions.luau",
		from = "\t\t\tours.owed = nil\n",
		to = "",
		breaks = "a restore drops the note with the data it was played on",
	},
	{
		file = "src/Upkeep.luau",
		from = " and internals.ended[key] ~= fence",
		to = "",
		breaks = "a request for a session this store released itself costs no data store request",
	},
	{
		file = "src/Upkeep.luau",
		from = "clock.spawn(LetGo.stray, context, key, fence)",
		to = "clock.spawn(function(...) end, context, key, fence)",
		breaks = "a key a live server holds with no session is freed for the server that asks",
	},
	{
		file = "src/Upkeep.luau",
		from = "if internals.opening[key] == nil then",
		to = "if true then",
		breaks = "a key is not freed under a load of it",
	},
	{
		file = "src/LetGo.luau",
		from = 'context.report(key, "a key held with no session was freed for the server asking for it")',
		to = "",
		breaks = "a stray key that was freed is reported: something left it held",
	},
	{
		file = "src/LetGo.luau",
		from = "context.report(key, `a key held with no session was not freed for the server asking for it: {err}`)",
		to = "",
		breaks = "a stray key the store refused to free is reported",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\t\telseif clock.now() + delay >= deadline then\n",
		to = "\t\t\telseif true then\n",
		breaks = "a key a load may have taken is let go of with more than one try",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\tconst deadline = clock.now() + config.loadTimeout\n",
		to = "\t\tconst deadline = context.deadline or clock.now() + config.loadTimeout\n",
		breaks = "the tries to let go have a window of their own: a load past its deadline has none",
	},
	{
		file = "src/LetGo.luau",
		from = "\t\t\tSpare.wait(context, Spare.RESERVE, deadline, context.closing)\n",
		to = "",
		breaks = "a try to let go is not fired at a spent budget",
	},
	{
		file = "src/LetGo.luau",
		from = "context.report(key, `a key its load may have taken could not be let go: {err}`)",
		to = "",
		breaks = "a key that could never be let go of is reported",
	},
	{
		file = "src/Open.luau",
		from = "const ok, answer = pcall(cancel)",
		to = "const ok, answer = true, cancel()",
		breaks = "a `cancel` that throws ends the load whole: nothing held, nothing subscribed",
	},
	{
		file = "src/Open.luau",
		from = "\t\telseif thrown.problem ~= nil and not result.ok then\n\t\t\terror(thrown.problem, 0)\n",
		to = "",
		breaks = "a `cancel` that threw reaches the load's caller",
	},
	{
		file = "src/Open.luau",
		from = "\tif thrown.problem ~= nil then\n\t\terror(thrown.problem, 0)\n\telseif waited then\n",
		to = "\tif waited then\n",
		breaks = "a `cancel` that threw while the load waited for a release reaches the caller",
	},
	{
		file = "src/Open.luau",
		from = 'thrown.problem = if answer == nil then "KeepBlox: `cancel` threw nil" else answer',
		to = "thrown.problem = answer",
		breaks = "a `cancel` that throws nil is an error the caller hears",
	},
	{
		file = "src/Open.luau",
		from = 'const released, problem = pcall(Session.release, context, session, "released")',
		to = 'const released, problem = true, Session.release(context, session, "released")',
		breaks = "a load nobody holds is released though its release throws",
	},
	{
		file = "src/Open.luau",
		from = "\t\t\tdelay = math.min(delay * 2, state.config.backoffMax)\n",
		to = "\t\t\tdelay = delay * 2\n",
		breaks = "the release of a load nobody holds is tried again with the backoff, capped",
	},
}
