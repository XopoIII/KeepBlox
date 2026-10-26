--!strict
--- Mutants of the spacing between a session's writes to its key (src/Upkeep.luau, src/Session.luau,
--- src/Send.luau, src/Enter.luau, src/Config.luau) and of a waiting load's standing request
--- (src/Lock.luau). Kept apart from tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/Upkeep.luau",
		from = "const spaced = now - session.lastWrite >= context.config.writeSpacing",
		to = "const spaced = true",
		breaks = "a write that can wait leaves the spacing after the key's last write",
	},
	{
		file = "src/Upkeep.luau",
		from = "\t\t\t\tsession.saveNow = true\n",
		to = "\t\t\t\tsession.saveSoon = true\n",
		breaks = "an owner whose beat stops landing stops vouching for it at once, however recently it wrote",
	},
	{
		file = "src/Session.luau",
		from = "\tsession.lastWrite = clock.now()\n",
		to = "",
		breaks = "a session's own write starts the spacing",
	},
	{
		file = "src/Send.luau",
		from = "\t\t\t\there.lastWrite = clock.now()\n",
		to = "",
		breaks = "a message sent where the key is held starts the spacing",
	},
	{
		file = "src/Enter.luau",
		from = "\t\tlastWrite = clock.now(),\n",
		to = "\t\tlastWrite = -math.huge,\n",
		breaks = "the claim starts the spacing",
	},
	{
		file = "src/Config.luau",
		from = 'assert(config.writeSpacing <= config.renew, "KeepBlox: writeSpacing must not exceed renew")',
		to = "",
		breaks = "a spacing longer than the renewal is refused",
	},
	{
		file = "src/Lock.luau",
		from = "\tif Record.isHere(request, identity) then\n\t\t-- Asked already",
		to = "\tif false then\n\t\t-- Asked already",
		breaks = "a waiting load's poll does not write its standing request again",
	},
}
