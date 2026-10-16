--!strict
--- A data store write whose transform throws fails, though the engine swallows the error (src/Call.luau):
--- UpdateAsync answers nil, nil, as if the transform had changed nothing (live check 2026-10-16). Every
--- lock-guarded write goes through `Call.update`, so a transform that breaks is a failed write, tried
--- again, never read as "nothing to do".
const Call = require("@keepblox/Call")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

Spec.test("CallUpdate: a transform that throws fails the call with its reason, and writes nothing", function()
	const world = World.new(1)
	const services = world:server({ name = "A" }).services
	const store = services.dataStores:GetDataStore("P")
	Sim.run(world.scheduler, "A", function()
		Spec.equal(
			{ Call.update(services.clock, 20, store, "k", function(): any
				error("broke", 0)
			end) },
			{ false, "the transform failed: broke" }
		)
		-- Nil, from a transform that returned it, is an answer: the call succeeded and wrote nothing.
		Spec.equal({ Call.update(services.clock, 20, store, "k", function(): any
			return nil
		end) }, { true })
		const ok, value = Call.update(services.clock, 20, store, "k", function(): any
			return { n = 1 }
		end)
		Spec.equal({ ok, value }, { true, { n = 1 } })
	end)
	Spec.equal(#world.backend:versions("P/global", "k"), 1)
end)

return nil
