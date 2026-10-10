--!strict
--- Mutants of the calls run apart from their caller (Apart): what a caller the game cancels inside
--- `store:load` or `profile:release()` may and may not leave behind (0.6.8, issue 31). Kept apart
--- from tests/Mutants.luau, which lists them with the rest.
---
--- Left out as equivalent in the harness: Apart's early return for a call that never yielded. Without
--- it the caller, still running, is woken; the fake scheduler passes over that in silence.

const SPAWNED = "\tclock.spawn(function()\n"
	.. "\t\tconst outcome = table.pack(pcall(fn, table.unpack(args, 1, args.n)))\n"
	.. "\t\tresults = outcome\n"
	.. "\t\tif not waiting then\n"
	.. "\t\t\t-- The call never yielded: the caller is still in `run` below and reads the results.\n"
	.. "\t\t\treturn\n"
	.. "\t\tend\n"
	.. '\t\tif coroutine.status(caller) ~= "dead" then\n'
	.. "\t\t\tclock.spawn(caller)\n"
	.. "\t\telseif not outcome[1] then\n"
	.. "\t\t\torphaned(outcome[2])\n"
	.. "\t\tend\n"
	.. "\tend)\n"

return {
	{
		file = "src/Apart.luau",
		from = SPAWNED,
		to = "\tresults = table.pack(pcall(fn, table.unpack(args, 1, args.n)))\n",
		breaks = "a call runs in a thread of the library's, so a cancelled caller does not stop it",
	},
	{
		file = "src/Apart.luau",
		from = '\t\tif coroutine.status(caller) ~= "dead" then\n\t\t\tclock.spawn(caller)\n',
		to = "\t\tif true then\n\t\t\tclock.spawn(caller)\n",
		breaks = "a cancelled caller of a load or a release is passed over, not woken",
	},
	{
		file = "src/Apart.luau",
		from = "\t\t\torphaned(outcome[2])\n",
		to = "\n",
		breaks = "a load or a release that throws after its caller was cancelled is reported",
	},
	{
		file = "src/Apart.luau",
		from = "\t\telseif not outcome[1] then\n",
		to = "\t\telse\n",
		breaks = "a call that ended well after its caller was cancelled is not reported as failed",
	},
	{
		file = "src/Open.luau",
		from = '\tconst orphaned = coroutine.status(asker) == "dead"\n',
		to = "\tconst orphaned = false\n",
		breaks = "the session a cancelled load opens is released, not left open with nobody holding it",
	},
	{
		file = "src/Open.luau",
		from = '\t\tSession.release(context, session, "released")\n\t\tstate.opening[key] = nil\n',
		to = '\t\tstate.opening[key] = nil\n\t\tSession.release(context, session, "released")\n',
		breaks = "shutdown waits for the release of the session a cancelled load opens",
	},
	{
		file = "src/Open.luau",
		from = "\t\t\tstate.opening[key] = nil\n\t\t\terror(result, 0)\n",
		to = "\t\t\terror(result, 0)\n",
		breaks = "a load that throws does not leave its key marked as opening",
	},
	{
		file = "src/Open.luau",
		from = "state.onError:fire(key, `a load failed after its caller was cancelled: {problem}`)",
		to = "",
		breaks = "a load that throws after its caller was cancelled reaches onError",
	},
	{
		file = "src/Enter.luau",
		from = "state.onError:fire(key, `a release failed after its caller was cancelled: {problem}`)",
		to = "",
		breaks = "a release that throws after its caller was cancelled reaches onError",
	},
	{
		file = "src/Enter.luau",
		from = "\t\t\tApart.run(clock, function(problem: any)\n"
			.. "\t\t\t\tstate.onError:fire(key, `a release failed after its caller was cancelled: {problem}`)\n"
			.. '\t\t\tend, Session.release, context, session, "released")\n',
		to = '\t\t\tSession.release(context, session, "released")\n',
		breaks = "a release whose caller is cancelled between two tries still retries its final write",
	},
	{
		file = "src/Settle.luau",
		from = ' and (asker == nil or coroutine.status(asker) ~= "dead")',
		to = "",
		breaks = 'a load of a key whose earlier load is being undone waits for it, and is not told "open"',
	},
	{
		file = "src/Settle.luau",
		from = "\t\tif (existing == nil or not existing.releasing) and",
		to = "\t\tif",
		breaks = "a load of a key this server is still releasing waits for the release",
	},
	{
		file = "src/Upkeep.luau",
		from = "(pending > 0 or next(internals.opening) ~= nil)",
		to = "(pending > 0)",
		breaks = "shutdown waits for a load in flight, cancelled or not, to let go of what it took",
	},
}
