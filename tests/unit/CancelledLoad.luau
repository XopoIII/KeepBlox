--!strict
--- A game may cancel a thread that is inside `store:load` (`task.cancel`, `coroutine.close`, its
--- script destroyed), at any point the load can park at. That ends the thread and nothing else: the
--- load is undone in a thread of the library's, the key is not left marked as opening or held without
--- a session, and a later load of it on the same server gets a session (src/Open.luau, src/Apart.luau,
--- src/Settle.luau; issue 31).
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Spec = require("../Spec")

const AFTERS: { LoadRig.After } = { "again", "alone", "close" }

const CASES = LoadScenes

for _, case in CASES do
	for _, after in AFTERS do
		Spec.test(`Cancelled load: {case.name}, its caller cancelled at every point, then {after}`, function()
			const swept = LoadRig.sweep(function(): LoadRig.Scene
				return case.build()
			end, after, case.coins)
			-- The load nobody cancelled is the one the others are measured against.
			Spec.equal(swept.result.ok, true, "the load nobody cancelled")
			Spec.equal(swept.result.profile.Data.coins, case.coins)
			Spec.equal(swept.cancels >= 3, true, `only {swept.cancels} cancels`)
			Spec.equal(swept.held > 0, case.parksHolding, `{swept.held} cancels found the key held`)
		end)
	end
end

return nil
