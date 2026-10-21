--!strict
--- Mutants of a quick rejoin while the player's earlier load is in flight (src/Opening.luau,
--- src/Settle.luau, src/Open.luau): the later load waits as the earlier one's heir and is handed the
--- session it opens. Kept apart from tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/Open.luau",
		from = "\tif heir and Opening.wants(heir) and Opening.gone(opening) and not state.closing() then\n",
		to = "\tif false then\n",
		breaks = "the session a load opens for a caller who is gone is handed to the load that waits for it",
	},
	{
		file = "src/Open.luau",
		from = "\tif heir and Opening.wants(heir) and Opening.gone(opening) and not state.closing() then\n",
		to = "\tif heir and Opening.wants(heir) and not state.closing() then\n",
		breaks = "a load whose caller is still there keeps its session, though another load waits",
	},
	{
		file = "src/Open.luau",
		from = "\t\tlooked.cancel = Opening.polled(opening)\n",
		to = "",
		breaks = "a load whose caller left goes on while an heir waits for it, so the key is claimed once",
	},
	{
		file = "src/Opening.luau",
		from = "\t\treturn own() and not Opening.wants(opening.heir)\n",
		to = "\t\treturn own()\n",
		breaks = "a load whose caller left goes on while an heir waits for it, so the key is claimed once",
	},
	{
		file = "src/Opening.luau",
		from = "\t\tand not (heir.cancel ~= nil and heir.cancel())\n",
		to = "",
		breaks = "an heir whose own player left again is not handed the session",
	},
	{
		file = "src/Opening.luau",
		from = '\t\tand coroutine.status(heir.thread) ~= "dead"\n',
		to = "",
		breaks = "an heir whose thread was cancelled is not handed the session",
	},
	{
		file = "src/Opening.luau",
		from = '\treturn coroutine.status(opening.asker) == "dead" or (opening.cancel ~= nil and opening.cancel())\n',
		to = '\treturn coroutine.status(opening.asker) == "dead"\n',
		breaks = 'a rejoin while the earlier load\'s player has left waits, and is not told "open"',
	},
	{
		file = "src/Settle.luau",
		from = "\t\tif inherited and not Opening.wants((opening :: Opening.Opening).heir) then\n",
		to = "\t\tif false then\n",
		breaks = "a later load becomes the heir of a load whose caller is gone",
	},
}
