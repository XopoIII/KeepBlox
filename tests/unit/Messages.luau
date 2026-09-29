--!strict
--- Offline messages: the stored queue, and exactly-once handling through the public API.
const KeepBlox = require("@keepblox")
const Messages = require("@keepblox/Messages")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

Spec.test("Messages: a key with nothing gets a queue-only record; indices keep counting", function()
	const record, sent = Messages.append(nil, { gift = 1 }, 10)
	Spec.equal(sent, { kind = "sent", index = 1, owner = nil, loadCount = 0 })
	Spec.equal(record, { GlobalUpdates = { 1, { { 1, { gift = 1 } } } } })
	const _, second = Messages.append(record, { gift = 2 }, 10)
	Spec.equal((second :: any).index, 2)
	Spec.equal(Messages.list(record), { { index = 1, message = { gift = 1 } }, { index = 2, message = { gift = 2 } } })
end)

Spec.test("Messages: a full queue refuses, and nothing already queued is dropped", function()
	local record: any = nil
	for index = 1, 3 do
		record = Messages.append(record, { n = index }, 3)
	end
	const refused, outcome = Messages.append(record, { n = 4 }, 3)
	Spec.equal(refused, nil)
	Spec.equal(outcome, { kind = "full" })
	Spec.equal(#Messages.list(record), 3)
	Spec.equal(select(2, Messages.append("not a profile", {}, 3)), { kind = "foreign" })
end)

Spec.test("Messages: ProfileService's older entries are read by their last element", function()
	const record = { Data = {}, MetaData = {}, GlobalUpdates = { 5, { { 5, 1, false, { gift = "old" } } } } }
	Spec.equal(Messages.list(record), { { index = 5, message = { gift = "old" } } })
	Messages.consume(record, { [5] = true })
	Spec.equal(Messages.list(record), {})
end)

const function setup(): (World.World, { [string]: any })
	const world = World.new(1)
	const stores = {}
	for _, name in { "A", "B" } do
		const services = world:server({ name = name }).services
		stores[name] = KeepBlox.store("Profiles", { template = { gifts = {} }, services = services })
	end
	return world, stores
end

const function gifted(profile: any)
	profile:onMessage(function(message: any, processed: () -> ())
		profile.Data.gifts[message.id] = (profile.Data.gifts[message.id] or 0) + 1
		processed()
	end)
end

Spec.test(
	"Messages: a message sent to an offline key is handled on load, and leaves the queue with its effect",
	function()
		const world, stores = setup()
		Sim.run(world.scheduler, "B", function()
			Spec.equal(stores.B:message("u_1", { id = "g1" }), { ok = true })
		end, 5)
		Sim.run(world.scheduler, "A", function()
			const result = stores.A:load("u_1")
			assert(result.ok, "loaded")
			gifted(result.profile)
			world.scheduler:wait(3)
			const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
			Spec.equal(record.Data.gifts, { g1 = 1 })
			Spec.equal(record.GlobalUpdates[2], {})
			result.profile:release()
		end, 30)
	end
)

Spec.test("Messages: a crash before the save redelivers the message; its effect lands once", function()
	const world = World.new(3)
	const a = world:server({ name = "A" })
	const storeA = KeepBlox.store("Profiles", { template = { gifts = {} }, services = a.services })
	Sim.run(world.scheduler, "A", function()
		storeA:message("u_1", { id = "g1" })
		const result = storeA:load("u_1")
		assert(result.ok, "loaded")
		-- Stall the save that would store the effect, then crash before it lands.
		world.faults:add({ op = "UpdateAsync", server = "A", hang = true })
		gifted(result.profile)
	end, 2)
	Spec.equal(((world.backend:latest("Profiles/global", "u_1") :: any).value).Data.gifts, {})
	a:crash()
	world.faults:clear()
	const b = world:server({ name = "B" })
	const storeB = KeepBlox.store("Profiles", { template = { gifts = {} }, services = b.services })
	Sim.run(world.scheduler, "B", function()
		const result = storeB:load("u_1")
		assert(result.ok, "taken over from the dead owner")
		gifted(result.profile)
		world.scheduler:wait(3)
		result.profile:release()
	end, world.scheduler.now + 120)
	const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(record.Data.gifts, { g1 = 1 })
	Spec.equal(record.GlobalUpdates[2], {})
end)

Spec.test("Messages: a handler that yields cannot let a second handler take the same message", function()
	const world, stores = setup()
	local calls = 0
	Sim.run(world.scheduler, "A", function()
		stores.A:message("u_1", { id = "g1" })
		const result = stores.A:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		for _ = 1, 2 do
			profile:onMessage(function(message: any, processed: () -> ())
				calls += 1
				world.scheduler:wait(1)
				profile.Data.gifts[message.id] = (profile.Data.gifts[message.id] or 0) + 1
				processed()
			end)
		end
		world.scheduler:wait(10)
		Spec.equal(profile.Data.gifts, { g1 = 1 })
		profile:release()
	end, 30)
	Spec.equal(calls, 1)
end)

Spec.test("Messages: the owner on another server hears of a new message and handles it within seconds", function()
	const world, stores = setup()
	local at = 0
	Sim.run(world.scheduler, "A", function()
		const result = stores.A:load("u_1")
		assert(result.ok, "loaded")
		result.profile:onMessage(function(message: any, processed: () -> ())
			at = world.scheduler.now
			result.profile.Data.gifts[message.id] = 1
			processed()
		end)
	end, 2)
	const sent = world.scheduler.now
	Sim.run(world.scheduler, "B", function()
		stores.B:message("u_1", { id = "g1" })
	end, sent + 10)
	Spec.truthy(at > 0 and at - sent < 5, `handled {at - sent} s after sending`)
end)

Spec.test("Messages: a message that cannot be stored is refused before it is sent", function()
	const world, stores = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.throws(function()
			stores.A:message("u_1", { bad = 0 / 0 })
		end, "message.bad: NaN cannot be stored")
		Spec.throws(function()
			stores.A:message("u_1", "text" :: any)
		end, "a message is a table")
	end, 5)
end)

return nil
