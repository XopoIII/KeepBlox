--!strict
const Services = require("@keepblox/Services")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

-- Two servers; B subscribes to "t" and logs what arrives and when.
const function pair(seed: number?): (World.World, Services.Messaging, { { data: any, at: number } })
	const world = World.new(seed or 1)
	const a = world:server({ name = "A" }).services.messaging
	const b = world:server({ name = "B" }).services.messaging
	const received = {}
	Sim.run(world.scheduler, "B", function()
		b:SubscribeAsync("t", function(message: Services.Message)
			table.insert(received, { data = message.Data, at = world.scheduler.now })
		end)
	end)
	return world, a, received
end

Spec.test("Messaging: a published message arrives within the delay range", function()
	const world, a, received = pair()
	local sentAt = 0
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", { hello = 1 })
		sentAt = world.scheduler.now
	end)
	Spec.equal(#received, 1)
	Spec.equal(received[1].data, { hello = 1 })
	const delay = received[1].at - sentAt
	Spec.truthy(delay >= 0.5 and delay <= 2, `delay {delay} in [0.5, 2]`)
end)

Spec.test("Messaging: Sent is the true Unix second of sending", function()
	const world = World.new(1, 1000)
	const b = world:server({ name = "B", skew = 500 }).services.messaging
	local sent = -1
	Sim.run(world.scheduler, "B", function()
		b:SubscribeAsync("t", function(message: Services.Message)
			sent = message.Sent
		end)
		world.scheduler:wait(10)
		b:PublishAsync("t", 1)
	end)
	Spec.equal(sent, 1010)
end)

Spec.test("Messaging: drop loses every copy, duplicate doubles every copy", function()
	const world, a, received = pair()
	world.bus.drop = 1
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", 1)
	end)
	Spec.equal(#received, 0)
	world.bus.drop = 0
	world.bus.duplicate = 1
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", 2)
	end)
	Spec.equal(#received, 2)
	Spec.equal(received[1].data, 2)
	Spec.equal(received[2].data, 2)
end)

Spec.test("Messaging: nothing arrives after Disconnect, or on another topic", function()
	const world = World.new(1)
	const a = world:server({ name = "A" }).services.messaging
	const b = world:server({ name = "B" }).services.messaging
	local count = 0
	Sim.run(world.scheduler, "B", function()
		const connection = b:SubscribeAsync("t", function()
			count += 1
		end)
		a:PublishAsync("t", 1)
		connection:Disconnect()
		a:PublishAsync("t", 2)
		a:PublishAsync("other", 3)
	end)
	Spec.equal(count, 0)
end)

Spec.test("Messaging: a partitioned server neither sends nor receives", function()
	const world, a, received = pair()
	world.bus.partitioned.A = true
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", 1)
	end)
	Spec.equal(#received, 0)
	world.bus.partitioned.A = nil
	world.bus.partitioned.B = true
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", 2)
	end)
	Spec.equal(#received, 0)
end)

Spec.test("Messaging: a crashed server's subscriptions go dead", function()
	const world = World.new(1)
	const a = world:server({ name = "A" }).services.messaging
	const server = world:server({ name = "B" })
	local count = 0
	Sim.run(world.scheduler, "B", function()
		server.services.messaging:SubscribeAsync("t", function()
			count += 1
		end)
	end)
	server:crash()
	Sim.run(world.scheduler, "A", function()
		a:PublishAsync("t", 1)
	end)
	Spec.equal(count, 0)
end)

Spec.test("Messaging: SubscribeAsync can hang, as in Team Test", function()
	const world = World.new(1)
	const b = world:server({ name = "B" }).services.messaging
	world.bus.hangSubscribe.B = true
	local subscribed = false
	world.scheduler:spawn(function()
		b:SubscribeAsync("t", function() end)
		subscribed = true
	end, "B")
	world.scheduler:run()
	Spec.equal(subscribed, false)
end)

Spec.test("Messaging: limits on topic length and message size", function()
	const world = World.new(1)
	const a = world:server({ name = "A" }).services.messaging
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			a:PublishAsync("", 1)
		end, "a topic of 0 characters")
		Spec.throws(function()
			a:PublishAsync(string.rep("t", 81), 1)
		end, "a topic of 81 characters")
		a:PublishAsync(string.rep("t", 80), string.rep("x", 1022))
		Spec.throws(function()
			a:PublishAsync("t", string.rep("x", 1023))
		end, "a message over 1024 bytes")
	end)
end)

return nil
