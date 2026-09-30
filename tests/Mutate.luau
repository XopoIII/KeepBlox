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

const Mutants = require("./Mutants")

type Mutant = Mutants.Mutant

const MUTANTS = Mutants

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
