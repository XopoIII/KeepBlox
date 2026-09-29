--!strict
--- Mutation adequacy of the suite: is the checker strong enough? Each mutant below is a small, plausible
--- slip in the code that keeps a guarantee, the kind a refactor could make. The suite runs once per
--- mutant and must fail; a mutant that survives shows a guarantee no spec proves. NaiveAdapter proves
--- the Ledger catches one unsafe library; this proves the specs catch each of these slips (as in
--- PyTation, arXiv 2601.19088: a green suite with full coverage can still miss faults).
---
---     luneblox run tests/Mutate --yes            (every mutant; about 30 s each)
---     luneblox run tests/Mutate --yes -- Lock    (only the mutants of files matching "Lock")
---
--- Left out as equivalent:
--- - Receipts' early return for a stored purchase: the granted list holds it too, so it is a fast path;
--- - Upkeep.listen's LoadCount check: every load subscribes on its own GUID's topic, so no message to
---   an older session can reach a later one's listener.
---
--- Every mutant's `from` must occur exactly once in its file, so a change to the code that moves it
--- fails here loudly instead of testing nothing. The source is always put back, even on an error.
const fs = require("@lune/fs")
const process = require("@lune/process")

type Mutant = { file: string, from: string, to: string, breaks: string }

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
		from = "if not Record.isHere(active, identity) or active[3] ~= identity.guid then",
		to = "if not Record.isHere(active, identity) then",
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
		from = "\t\tif unsure then\n\t\t\tdisown(context, key)",
		to = "\t\tif false then\n\t\t\tdisown(context, key)",
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
		file = "src/Lease.luau",
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
		file = "src/Versions.luau",
		from = "if not table.find(before, id) then",
		to = "if false then",
		breaks = "a restore names the purchases it rolled back",
	},
}

const function count(text: string, pattern: string): number
	local found, start = 0, 1
	while true do
		const first, last = string.find(text, pattern, start, true)
		if first == nil then
			return found
		end
		found += 1
		start = (last :: number) + 1
	end
end

const function suitePasses(): boolean
	const result = process.exec("luneblox", { "run", "tests/Run", "--yes" })
	return result.ok
end

local only: string? = nil
for _, arg in process.args do
	if string.sub(arg, 1, 1) ~= "-" then
		only = arg
	end
end
-- Every chosen mutant must still match its code before any runs, so a stale one fails in a second.
const chosen: { [number]: Mutant } = {}
for index, mutant in MUTANTS do
	if only == nil or string.find(mutant.file, only :: string, 1, true) then
		const occurrences = count(fs.readFile(mutant.file), mutant.from)
		assert(occurrences == 1, `mutant {index} ({mutant.file}): its code occurs {occurrences} times, not once`)
		chosen[index] = mutant
	end
end

const survivors: { Mutant } = {}
local ran = 0
for index, mutant in MUTANTS do
	if chosen[index] == nil then
		continue
	end
	const original = fs.readFile(mutant.file)
	const first, last = string.find(original, mutant.from, 1, true)
	fs.writeFile(
		mutant.file,
		string.sub(original, 1, (first :: number) - 1) .. mutant.to .. string.sub(original, (last :: number) + 1)
	)
	const ok, passed = pcall(suitePasses)
	fs.writeFile(mutant.file, original)
	assert(ok, `mutant {index}: the suite could not run: {passed}`)
	ran += 1
	print(`{if passed then "SURVIVED" else "killed  "} {index} {mutant.file}: {mutant.breaks}`)
	if passed then
		table.insert(survivors, mutant)
	end
end

print(`{ran - #survivors} of {ran} mutants killed`)
process.exit(if #survivors == 0 then 0 else 1)
