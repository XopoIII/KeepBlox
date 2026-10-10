--!strict
--- The mutants tests/Mutate runs: each a small slip in code that keeps a guarantee, and what it breaks.
--- Every `from` must occur exactly once in its file.

export type Mutant = { file: string, from: string, to: string, breaks: string }

const MUTANTS: { Mutant } = {
	{
		file = "src/Lock.luau",
		from = "if not Record.isHere(active, identity) or meta.SessionLoadCount ~= loadCount then",
		to = "if not Record.isHere(active, identity) then",
		breaks = "a save from an older session of this server is refused (guarantee 2)",
	},
	{
		file = "src/Lock.luau",
		from = "if not Record.isHere(active, identity) or meta.SessionLoadCount ~= loadCount then",
		to = "if meta.SessionLoadCount ~= loadCount then",
		breaks = "a save from another server is refused (guarantee 2)",
	},
	{
		file = "src/Lock.luau",
		from = "meta.SessionLoadCount = (meta.SessionLoadCount or 0) + 1",
		to = "meta.SessionLoadCount = meta.SessionLoadCount or 1",
		breaks = "every claim starts a new session (guarantee 3)",
	},
	{
		file = "src/Lock.luau",
		from = "\t\telseif Record.isHere(request, identity) then\n\t\t\tconst claim = take(record, identity, now, mode)",
		to = "\t\telseif true then\n\t\t\tconst claim = take(record, identity, now, mode)",
		breaks = "a steal yields to a third server that asked since",
	},
	{
		file = "src/Lock.luau",
		from = "\t\t\tand expect.lease == owner.lease\n",
		to = "\n",
		breaks = "a quiet takeover needs the lease it watched stand still",
	},
	{
		file = "src/Lock.luau",
		from = "\tif payload.release then\n\t\tmeta.ActiveSession = nil",
		to = "\tif false then\n\t\tmeta.ActiveSession = nil",
		breaks = "a release frees the key",
	},
	{
		file = "src/Lock.luau",
		from = "const handOver = request ~= nil and not Record.isHere(request, identity)",
		to = "const handOver = false",
		breaks = "an owner hands over at its next write",
	},
	{
		file = "src/Lock.luau",
		from = "else active and active[3] == identity.guid",
		to = "else true",
		breaks = "disown frees only the load that holds the key",
	},
	{
		file = "src/Lock.luau",
		from = "if mode and mode.byBeat and not owner.memory then",
		to = "if false then",
		breaks = "a steal on the beat's word needs the record to still vouch for the beat",
	},
	{
		file = "src/Lock.luau",
		from = "and (not expect.byBeat or owner.memory)",
		to = "",
		breaks = "a quiet takeover on the beat's word needs the record to still vouch for it",
	},
	{
		file = "src/Upkeep.luau",
		from = "return clock.now() - sentAt <= 1.5 * context.config.heartbeat",
		to = "return true",
		breaks = "an owner whose beats stop landing withdraws its beat before it could be judged dead",
	},
	{
		file = "src/Claim.luau",
		from = "\t\tif unsure then\n\t\t\tLetGo.disown(context, key)",
		to = "\t\tif false then\n\t\t\tLetGo.disown(context, key)",
		breaks = "an abandoned claim leaves no phantom owner",
	},
	{
		file = "src/Claim.luau",
		from = "\t\t\telse\n\t\t\t\tsteal = now - current.since >= config.death",
		to = "\t\t\telse\n\t\t\t\tsteal = now - current.since >= config.death / 4",
		breaks = "a slow owner is not taken for a dead one",
	},
	{
		file = "src/Lease.luau",
		from = "return if now - (watch.countSince :: number) >= 2 * context.config.heartbeat then",
		to = "return if now - (watch.countSince :: number) >= context.config.heartbeat / 4 then",
		breaks = "a live owner's beat is not judged dead between two beats",
	},
	{
		file = "src/Lease.luau",
		from = "or snapshot.c ~= loadCount or",
		to = "or",
		breaks = "only the dead session's own snapshot is recovered",
	},
	{
		file = "src/Upkeep.luau",
		from = "and (fence == true or fence == session.loadCount)",
		to = "",
		breaks = "a stale hand-over request never ends a later session",
	},
	{
		file = "src/Receipts.luau",
		from = "if not table.find(session.receipts, id) then",
		to = "if true then",
		breaks = "a purchase granted once is not granted again (guarantee 9)",
	},
	{
		file = "src/Session.luau",
		from = 'if result.kind == "lost" then',
		to = 'if result.kind == "never" then',
		breaks = "a session that lost the key freezes (guarantee 6)",
	},
	{
		file = "src/Validate.luau",
		from = "if utf8.len(value) == nil then",
		to = "if false then",
		breaks = "a string that is not UTF-8 is refused before the write (guarantee 7)",
	},
	{
		file = "src/Validate.luau",
		from = "if state.open[value] then",
		to = "if false and state.open[value] then",
		breaks = "a cycle is refused, not recursed into",
	},
	{
		file = "src/Versions.luau",
		from = "ours.schemaVersion = if storedAt > 0 then storedAt else nil",
		to = "",
		breaks = "a restored version is migrated from its own schema version",
	},
	{
		file = "src/Session.luau",
		from = "schemaVersion = if data ~= nil then plan.write else nil,",
		to = "schemaVersion = if data ~= nil then plan.version else nil,",
		breaks = "a save stores the version its data is at (a release can be rolled back)",
	},
	{
		file = "src/Session.luau",
		from = "storable, turned = Migrate.store(plan, Record.copy(snapshot))",
		to = "storable, turned = snapshot, nil",
		breaks = "a release that can be rolled back stores its data turned down",
	},
	{
		file = "src/Snapshots.luau",
		from = "v = context.plan.write,",
		to = "v = context.plan.version,",
		breaks = "a snapshot is at the version this server stores",
	},
	{
		file = "src/Trade.luau",
		from = "schemaVersion = if data ~= nil then context.plan.write else nil,",
		to = "schemaVersion = nil,",
		breaks = "a trade stores the version its data is at (no migration runs twice)",
	},
	{
		file = "src/Open.luau",
		from = "version = plan.write,",
		to = "version = plan.version,",
		breaks = "a new profile is stored at the version this server stores",
	},
	{
		file = "src/Migrate.luau",
		from = "back.ok and same(back.data, template),",
		to = "true,",
		breaks = "a down that does not undo its up is refused when the store is made",
	},
	{
		file = "src/Record.luau",
		from = 'error("KeepBlox: too deep to copy", 0)\n\tend\n\tconst result: { [any]: any } = table.clone(value)\n\tif getmetatable(result) ~= nil then',
		to = 'error("KeepBlox: too deep to copy", 0)\n\tend\n\tconst result: { [any]: any } = table.clone(value)\n\tif false then',
		breaks = "a copy of the data carries no metatable",
	},
	{
		file = "src/Record.luau",
		from = "result[key] = copyFast(item, depth + 1)",
		to = "result[key] = item",
		breaks = "a copy shares no table with the data (a snapshot does not change after it is taken)",
	},
	{
		file = "src/Validate.luau",
		from = '\t\ttable.insert(state.chunks, table.concat(parts, ",", 1, state.count))\n\t\tstate.count = 0',
		to = '\t\ttable.insert(state.chunks, table.concat(parts, ",", 1, state.count - 1))\n\t\tstate.count = 0',
		breaks = "a large value's text keeps every part (its text decides whether it is written)",
	},
	{
		file = "src/Session.luau",
		from = "\telseif encoded == nil then\n\t\t-- One bad value must not cost",
		to = "\telseif false then\n\t\t-- One bad value must not cost",
		breaks = "one bad value does not cost the play around it (poison)",
	},
	{
		file = "src/Snapshots.luau",
		from = 'if #Repair.run(data, "Data") > 0 then',
		to = "if false then",
		breaks = "a bad value does not stop the crash snapshots",
	},
	{
		file = "src/Repair.luau",
		from = "tbl[key] = mend(value)",
		to = "tbl[key] = nil",
		breaks = "a bad string keeps its text, only its bad bytes replaced",
	},
	{
		file = "src/Record.luau",
		from = "return if ok then result else copyShared(value, {})",
		to = "return if ok then result else nil",
		breaks = "data that contains itself does not break the copy",
	},
	{
		file = "src/Claim.luau",
		from = "local handOverDelay = HAND_OVER_POLL",
		to = "local handOverDelay = config.backoffMin * 2",
		breaks = "a live owner's hand-over is caught within half a second",
	},
	{
		file = "src/Lease.luau",
		from = "return math.clamp(due, 0.05, 1)",
		to = "return 1",
		breaks = "a dead owner's beat is looked at again the moment it could be judged dead",
	},
	{
		file = "src/Versions.luau",
		from = "if not table.find(before, id) then",
		to = "if false then",
		breaks = "a restore names the purchases it rolled back",
	},
	{
		file = "src/Versions.luau",
		from = 'if string.find(tostring(value), "Error code: 25", 1, true) then "noVersion" else "failed"',
		to = '"failed"',
		breaks = "a version id that is not one answers noVersion",
	},
	{
		file = "src/Claim.luau",
		from = "Spare.wait(context, if tries == 0 then 1 else Spare.RESERVE, deadline,",
		to = "Spare.wait(context, 0, deadline,",
		breaks = "under overload, loads leave the budget to saves, so hand-overs keep going",
	},
	{
		file = "src/Open.luau",
		from = "\tcontext.deadline = deadline\n",
		to = "\n",
		breaks = "a load answers within loadTimeout in all, not per step",
	},
	{
		file = "src/Snapshots.luau",
		from = "or (session.releasing and not final)",
		to = "or session.releasing",
		breaks = "a release that cannot land by the shutdown deadline leaves its data in a last beat",
	},
	{
		file = "src/Snapshots.luau",
		from = "\t\tif not session.releasing then\n\t\t\tsession.profile.onSaving:fire(false, nil)\n\t\tend\n",
		to = "\n",
		breaks = "a game that writes Data only in onSaving loses about one beat to a crash",
	},
	{
		file = "src/Upkeep.luau",
		from = "\t\twhile not target.done do",
		to = "\t\twhile delay == LISTEN_RETRY_MIN and not target.done do",
		breaks = "a failed hand-over subscription is retried, or a hand-over waits for the next write",
	},
	{
		file = "src/Signal.luau",
		from = "table.remove(listeners, index)",
		to = "",
		breaks = "a disconnected listener is let go, so a long-lived signal does not grow",
	},
}

-- The heartbeat snapshots of large profiles and the hand-over's reused verdict (0.5).
for _, mutant in require("./MutantsSnapshots") do
	table.insert(MUTANTS, mutant)
end
-- The write lane and the shared manual save under a cancelled caller (0.6.7).
for _, mutant in require("./MutantsLane") do
	table.insert(MUTANTS, mutant)
end
-- A load and a release under a cancelled caller (0.6.8).
for _, mutant in require("./MutantsApart") do
	table.insert(MUTANTS, mutant)
end
-- The loose ends of giving a key back (0.6.10).
for _, mutant in require("./MutantsLooseEnds") do
	table.insert(MUTANTS, mutant)
end
-- What a load that gives up, fails or throws past its claim gives back (0.6.9).
for _, mutant in require("./MutantsGiveBack") do
	table.insert(MUTANTS, mutant)
end

return MUTANTS
