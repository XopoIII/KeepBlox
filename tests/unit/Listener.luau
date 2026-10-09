--!strict
--- The hand-over listener (src/Upkeep.luau): a session hears the requests other servers send it.
--- Subscribing never holds up the load, and a subscribe that fails is retried: without the listener a
--- hand-over would surface only at the owner's next write, up to `renew` seconds late.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

Spec.test("Listener: a failed subscribe is retried, and the hand-over still lands in seconds", function()
	const world = World.new(1)
	const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	-- A's first two subscribes fail; the retried one lands.
	world.faults:add({
		op = "SubscribeAsync",
		server = "A",
		error = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)",
		times = 2,
	})
	local ended = "still open"
	local endedAt = 0
	local connectedAfterLoad = -1
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded with the subscription down")
		-- The load answered while no subscription had landed: subscribing never holds it up.
		connectedAfterLoad = world.bus:connected("A")
		result.profile.onEnded:connect(function(reason: string)
			ended = reason
			endedAt = world.scheduler.now
		end)
	end, 30)
	Spec.equal(connectedAfterLoad, 0)
	-- The retries landed one meanwhile.
	Spec.equal(world.bus:connected("A"), 1)
	world.faults:clear()
	local askedAt = 0
	Sim.run(world.scheduler, "B", function()
		askedAt = world.scheduler.now
		const result = b:load("u_1")
		assert(result.ok, `B loaded ({(result :: any).reason})`)
		result.profile:release()
	end, world.scheduler.now + 120)
	Spec.equal(ended, "handedOver")
	Spec.truthy(endedAt - askedAt < 30, `handed over {endedAt - askedAt} s after the ask, not at the next renewal`)
end)

return nil
