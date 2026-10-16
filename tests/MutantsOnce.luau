--!strict
--- Mutants of what keeps a change to once (issue 41, src/Once.luau): the ids of a shared update and of
--- a message, the deadline in their transforms, the bounds of the id lists, the fence on lock-guarded
--- writes and on heartbeats, and the claim that finds its own load's key. Kept apart from
--- tests/Mutants.luau, which lists them with the rest.
---
--- Left out as equivalent: the fence's `>=` as `>`. It lets the same write land twice, which writes the
--- same data again; only the lease moves one more, and nothing reads it as a count of writes.

return {
	{
		file = "src/Shared.luau",
		from = "if Once.seen(ours.applied, id) then",
		to = "if false then",
		breaks = "an update tried again after it landed is not applied twice",
	},
	{
		file = "src/Shared.luau",
		from = "\t\t\t\t\tours.applied = Once.note(ours.applied, id, startedAt, clock.time(), lifetime + Once.SKEW)\n",
		to = "\n",
		breaks = "an update's id is stored with its change",
	},
	{
		file = "src/Shared.luau",
		from = "elseif clock.now() - started > lifetime then",
		to = "elseif false then",
		breaks = "a try of an update that runs after its call's time changes nothing",
	},
	{
		file = "src/Messages.luau",
		from = "if mark and Once.seen(queue[3], mark.id) then",
		to = "if false then",
		breaks = "a message tried again after it landed is not queued twice",
	},
	{
		file = "src/Messages.luau",
		from = "\t\tqueue[3] = Once.note(queue[3], mark.id, mark.at, mark.time(), mark.keep)\n",
		to = "\n",
		breaks = "a message's id is stored with it",
	},
	{
		file = "src/Messages.luau",
		from = "elseif mark and mark.now() > mark.deadline then",
		to = "elseif false then",
		breaks = "a try of a send that runs after its call's time queues nothing",
	},
	{
		file = "src/Once.luau",
		from = "and now - entry[2] <= keep",
		to = "and true",
		breaks = "an id is forgotten once no try of its call can land",
	},
	{
		file = "src/Once.luau",
		from = "while #kept > KEEP do",
		to = "while false do",
		breaks = "a list holds at most KEEP ids",
	},
	{
		file = "src/Once.luau",
		from = "and stored[2] >= stamp then",
		to = "and false then",
		breaks = "a lock-guarded write that lands after a newer one changes nothing",
	},
	{
		file = "src/Lock.luau",
		from = "elseif not Once.fence(Record.ours(meta), loadCount, payload.stamp) then",
		to = "elseif false then",
		breaks = "a save that lands after a newer one changes nothing",
	},
	{
		file = "src/Session.luau",
		from = "\t\tstamp = Once.stamp(),\n",
		to = "\n",
		breaks = "a session's saves are fenced",
	},
	{
		file = "src/Lock.luau",
		from = "if mine and Record.isHere(active, identity) and active[3] == identity.guid then",
		to = "if false then",
		breaks = "a claim that finds its own load's key writes nothing and keeps the load's session",
	},
	{
		file = "src/Lock.luau",
		from = "elseif mine and active == nil then",
		to = "elseif false then",
		breaks = "a claim that lands after its load let the key go takes nothing",
	},
	{
		file = "src/Lock.luau",
		from = "previous = Owed.again(meta)",
		to = "previous = nil",
		breaks = "a claim tried again after it landed recovers from the owner it took the key from",
	},
	{
		file = "src/Lock.luau",
		from = "\tRecord.ours(meta).from = nil\n",
		to = "\n",
		breaks = "a load's save clears the note of the owner its claim took the key from",
	},
	{
		file = "src/Lease.luau",
		from = "if latest and latest >= stamp then",
		to = "if false then",
		breaks = "a heartbeat that lands after a newer one changes nothing",
	},
}
