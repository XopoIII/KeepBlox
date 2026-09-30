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

Spec.test("Messaging: Sent is the true Unix time of sending, with milliseconds, not the skewed clock", function()
	const world = World.new(1, 1000)
	const b = world:server({ name = "B", skew = 500 }).services.messaging
	local sent, at = -1, -1
	Sim.run(world.scheduler, "B", function()
		b:SubscribeAsync("t", function(message: Services.Message)
			sent = message.Sent
		end)
		world.scheduler:wait(10.25)
		at = world.scheduler.now
		b:PublishAsync("t", 1)
	end)
	Spec.equal(sent, math.floor((1000 + at) * 1000) / 1000)
	Spec.truthy(sent ~= math.floor(sent), `{sent} has a fraction`)
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

-- The limits as measured live (Studio, 2026-09-30), with the engine's error texts.
Spec.test("Messaging: limits on topic length and message size", function()
	const world = World.new(1)
	const a = world:server({ name = "A" }).services.messaging
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			a:PublishAsync("", 1)
		end, "UNMODELLED: an empty topic")
		Spec.throws(function()
			a:PublishAsync(string.rep("t", 81), 1)
		end, "Topic names cannot be more than 80 characters.")
		-- A string may have 1024 bytes (two-byte characters count twice).
		a:PublishAsync(string.rep("t", 80), string.rep("x", 1024))
		a:PublishAsync("t", string.rep("\u{E9}", 512))
		Spec.throws(function()
			a:PublishAsync("t", string.rep("x", 1025))
		end, "Cannot publish, data exceeded 1kb")
		Spec.throws(function()
			a:PublishAsync("t", string.rep("\u{E9}", 513))
		end, "Cannot publish, data exceeded 1kb")
		-- Any other value: 940 bytes of JSON.
		a:PublishAsync("t", { s = string.rep("x", 932) })
		a:PublishAsync("t", table.create(469, 1))
		Spec.throws(function()
			a:PublishAsync("t", { s = string.rep("x", 933) })
		end, "Cannot publish, data exceeded 1kb")
		Spec.throws(function()
			a:PublishAsync("t", table.create(470, 1))
		end, "Cannot publish, data exceeded 1kb")
	end)
end)

return nil
