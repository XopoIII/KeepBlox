--!strict
--- Mutants of a tally (src/Tally.luau, src/TallyCount.luau, src/TallyShard.luau): the serial that keeps
--- a batch to once, the entries a shard forgets, the batch a read settles, the newer of two answers, the
--- late try's guard, the budget's reserve, the shutdown's writes and the watchers. Kept apart from
--- tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/TallyShard.luau",
		from = 'if type(entry) == "table" and type(entry[1]) == "number" and entry[1] >= serial then',
		to = "if false then",
		breaks = "a batch whose write landed and then failed is counted once",
	},
	{
		file = "src/TallyShard.luau",
		from = "and now - other[2] <= remember",
		to = "and true",
		breaks = "a shard forgets the entry of a server silent past `remember`",
	},
	{
		file = "src/TallyCount.luau",
		from = "if shard == mine and batch and seen.serial and seen.serial >= batch.serial then",
		to = "if false then",
		breaks = "a batch a read shows landed is settled, not counted twice nor written again",
	},
	{
		file = "src/TallyCount.luau",
		from = "if known == nil or seen.version > known.version then",
		to = "if true then",
		breaks = "an answer older than what a write saw is not taken",
	},
	{
		file = "src/TallyCount.luau",
		from = "if clock.now() - started > context.remember / 2 then",
		to = "if false then",
		breaks = "a try run after its server's entry was forgotten changes nothing",
	},
	{
		file = "src/TallyCount.luau",
		from = "\t\tcount.pending = 0\n",
		to = "",
		breaks = "what goes in a batch is no longer pending",
	},
	{
		file = "src/Tally.luau",
		from = 'if budget("StandardWrite") < reserve then',
		to = "if false then",
		breaks = "a turn writes nothing while the budget is nearly spent",
	},
	{
		file = "src/Tally.luau",
		from = 'if budget("StandardRead") < shards + reserve then',
		to = "if false then",
		breaks = "a turn reads nothing while the budget is nearly spent",
	},
	{
		file = "src/Tally.luau",
		from = "\t\tclosing = true\n\t\tif next(counts) == nil then",
		to = "\t\tclosing = true\n\t\tif true then",
		breaks = "a server that closes writes what it added first",
	},
	{
		file = "src/Tally.luau",
		from = "\t\t\tcount.pending += amount\n\t\t\tstart()\n",
		to = "\t\t\tcount.pending += amount\n",
		breaks = "a server's adds are written at its turns",
	},
	{
		file = "src/Tally.luau",
		from = "\t\t\t\tprepare()\n\t\t\t\tread(key, count)\n\t\t\t\tif connected then",
		to = "\t\t\t\tprepare()\n\t\t\t\tif connected then",
		breaks = "a watcher is told the total after its first read",
	},
	{
		file = "src/Tally.luau",
		from = "if total == count.told then",
		to = "if false then",
		breaks = "a watcher is told the total only when it changes",
	},
	{
		file = "src/Tally.luau",
		from = "\t\t\t\t\t\ttable.remove(count.watchers, index)\n",
		to = "",
		breaks = "a watcher that leaves is not told again",
	},
}
