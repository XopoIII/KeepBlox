--!strict
--- Mutants of the write lane (Serial) and of the shared manual save (Session.save): what a caller the
--- game cancels may and may not take with it (0.6.7). Kept apart from tests/Mutants.luau, which lists
--- them with the rest.

return {
	{
		file = "src/Serial.luau",
		from = "\t\t\t\tbusy = true\n\t\t\t\tclock.spawn(job)\n",
		to = "\t\t\t\tbusy = true\n\t\t\t\tjob()\n",
		breaks = "a caller cancelled in the middle of its call does not keep the lane",
	},
	{
		file = "src/Serial.luau",
		from = "\t\t\t\tconst outcome = table.pack(pcall(fn, table.unpack(args, 1, args.n)))\n",
		to = '\t\t\t\tif coroutine.status(caller) == "dead" then\n\t\t\t\t\trelease()\n\t\t\t\t\treturn\n\t\t\t\tend\n'
			.. "\t\t\t\tconst outcome = table.pack(pcall(fn, table.unpack(args, 1, args.n)))\n",
		breaks = "a queued caller cancelled while waiting does not lose its call, nor those who joined its save",
	},
	{
		file = "src/Serial.luau",
		from = 'if coroutine.status(caller) ~= "dead" then',
		to = "if true then",
		breaks = "a cancelled caller is passed over, not woken",
	},
	{
		file = "src/Serial.luau",
		from = "\t\t\t\t\torphaned(outcome[2])\n",
		to = "\n",
		breaks = "a call that throws after its caller was cancelled is reported",
	},
	{
		file = "src/Serial.luau",
		from = "if orphaned == nil then\n\t\t\t\t\t\terror(outcome[2], 0)\n",
		to = "if orphaned == nil then\n\t\t\t\t\t\treturn\n",
		breaks = "with nobody to tell, a cancelled caller's failed call fails the lane's own thread",
	},
	{
		file = "src/Serial.luau",
		from = "\t\t\t\tresults = outcome\n\t\t\t\trelease()\n",
		to = "\t\t\t\tresults = outcome\n\t\t\t\tclock.spawn(function()\n\t\t\t\t\tclock.wait()\n\t\t\t\t\trelease()\n\t\t\t\tend)\n",
		breaks = "the lane passes to the next call before the caller goes on",
	},
	{
		file = "src/Session.luau",
		from = "\t\tif session.pending == pending then\n\t\t\tsession.pending = nil\n\t\tend\n",
		to = "\n",
		breaks = "a manual save asked for after the shared one started gets a save of its own",
	},
	{
		file = "src/Session.luau",
		from = 'const ok, stored = pcall(write, context, session, false, "released", false)',
		to = 'const ok, stored = true, write(context, session, false, "released", false)',
		breaks = "a write that throws still answers those who joined it",
	},
	{
		file = "src/Session.luau",
		from = "pending.stored = ok and stored == true",
		to = "pending.stored = ok",
		breaks = "a save that was not stored answers false to those who joined it",
	},
	{
		file = "src/Session.luau",
		from = 'if coroutine.status(waiter) ~= "dead" then',
		to = "if true then",
		breaks = "a save's joined caller cancelled while waiting is passed over, not woken",
	},
	{
		file = "src/Open.luau",
		from = "state.onError:fire(key, `a write failed after its caller was cancelled: {problem}`)",
		to = "",
		breaks = "a write that throws after its caller was cancelled reaches onError",
	},
}
