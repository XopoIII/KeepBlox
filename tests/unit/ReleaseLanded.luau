--!strict
--- A release whose write lands but answers with an error ("a failed write does not always guarantee that
--- the backend write did not occur", error-codes-and-limits) is tried again. The landed try already let
--- the key go, so the retry must end the session as released, not lost: the data is stored, and a game
--- told "lost" raises an alarm over play that is safe. A key another server took meanwhile is still lost.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

const function stored(world: World.World): any
	return (world.backend:latest("Profiles/global", "u_1") :: any).value
end

Spec.test("ReleaseLanded: a release that landed unanswered ends the session as released", function()
	const world = World.new(7)
	const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	const errors: { string } = {}
	a.onError:connect(function(_: string, message: string, kind: KeepBlox.ErrorKind)
		table.insert(errors, `{message} [{kind}]`)
	end)
	local reason = "still open"
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.onEnded:connect(function(why: string)
			reason = why
		end)
		result.profile.Data.coins = 7
		world.faults:add({
			op = "UpdateAsync",
			server = "A",
			key = "u_1",
			error = "502: API Services rejected request",
			after = true,
			times = 1,
		})
		result.profile:release()
	end, 60)
	Spec.equal(#errors, 1, "the first try of the release answered with an error")
	Spec.equal(reason, "released")
	Spec.equal(stored(world).Data, { coins = 7 })
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
	Spec.equal(stored(world).MetaData.SessionLoadCount, 1)
end)

Spec.test("ReleaseLanded: a release that finds the key taken and let go elsewhere is still lost", function()
	-- The key is removed and claimed afresh by B, so its load count starts over at A's: only the owner
	-- tells B's release from A's own.
	const world = World.new(8)
	const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	const eraser = world:server({ name = "C" }).services.dataStores:GetDataStore("Profiles")
	local reason = "still open"
	Sim.run(world.scheduler, "A", function()
		const old = a:load("u_1")
		assert(old.ok, "A loaded")
		old.profile.onEnded:connect(function(why: string)
			reason = why
		end)
		eraser:RemoveAsync("u_1")
		const fresh = b:load("u_1")
		assert(fresh.ok, `B loaded ({(fresh :: any).reason})`)
		fresh.profile.Data.coins = 3
		fresh.profile:release()
		old.profile.Data.coins = 50
		old.profile:release()
	end, 60)
	Spec.equal(stored(world).MetaData.SessionLoadCount, 1, "the count started over")
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
	Spec.equal(stored(world).Data, { coins = 3 })
	Spec.equal(reason, "lost")
end)

return nil
