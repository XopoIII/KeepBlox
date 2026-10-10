--!strict
--- A load that gives up, because its player left (`cancel`) or its server is shutting down, at any
--- point the world can stand at while it runs, gives back whole what it took, or keeps it: the next
--- server reads everything a dead owner had played, and no key is left held with nobody to release
--- it (src/Claim.luau, src/LetGo.luau, src/Open.luau; issues 33 and 34).
const GiveUpRig = require("./GiveUpRig")
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Spec = require("../Spec")

const WAYS: { GiveUpRig.Way } = { "left", "close" }

for _, case in LoadScenes do
	for _, way in WAYS do
		Spec.test(`Load gives up: {case.name}, {way} at every point, then another server loads it`, function()
			const swept = GiveUpRig.sweep(function(): LoadRig.Scene
				return case.build()
			end, way, case.coins, case.within)
			-- The load nobody stopped is the one the others are measured against.
			Spec.equal(swept.result.ok, true, "the load nobody stopped")
			Spec.equal(swept.result.profile.Data.coins, case.coins)
			Spec.equal(swept.points >= 3, true, `only {swept.points} points`)
			-- The sweep reaches the load while it holds the key (it parks there to store the dead owner's
			-- last beat, or to settle the trade) exactly in the scenes that have such a moment.
			Spec.equal(swept.held > 0, case.parksHolding, `{swept.held} points found the key held`)
			if way == "close" then
				-- A shutdown is looked at to the load's very end: each one answered "closing".
				Spec.equal(swept.answers, { closing = swept.points })
			else
				-- `cancel` is looked at for the last time as the claim lands: a player who leaves after
				-- that gets the profile, and only where the load parks past its claim.
				Spec.equal((swept.answers.ok or 0) > 0, case.parksHolding, `{swept.answers.ok} loads answered ok`)
				Spec.equal(swept.answers, { cancelled = swept.points - (swept.answers.ok or 0), ok = swept.answers.ok })
			end
			-- Whenever the key was A's to free, the next server had it at its first request.
			Spec.equal(swept.slowestFreed <= GiveUpRig.FREE, true, `{swept.slowestFreed} s`)
		end)
	end
end

return nil
