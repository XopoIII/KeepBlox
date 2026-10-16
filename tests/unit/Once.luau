--!strict
--- A change that adds to what is stored lands once, though its call failed or timed out and was tried
--- again (issue 41, src/Once.luau): a shared document's `update` and a store's `message`. A call that
--- seemed to fail may have gone through ("a failed write does not always guarantee that the backend
--- write did not occur", error-codes-and-limits), and one the library stopped waiting for keeps running.
--- Each fault stands beside the same call when the failure is genuine (nothing landed): retried, it
--- lands once too.
const Errors = require("@fakes/Errors")
const Faults = require("@fakes/Faults")
const KeepBlox = require("@keepblox")
const Once = require("@keepblox/Once")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { bank = 0 }

-- The faults the first try of a call meets, by name. Every one fires once, on server A's first call.
const FAULTS: { [string]: Faults.Rule } = {
	-- The write lands, then the call errors.
	landedThenFailed = { error = Errors.rejected(), after = true },
	-- The write lands, and its answer comes after the caller stopped waiting (20 s).
	landedAnsweredLate = { delay = 30, after = true },
	-- The request waits past the caller's deadline, then runs on what is stored by then.
	timedOutLandedLate = { delay = 30 },
	-- Genuine failures: nothing lands.
	failed = { error = Errors.rejected() },
	lost = { hang = true },
}

const function arm(world: World.World, key: string, name: string)
	const rule = table.clone(FAULTS[name])
	rule.op, rule.key, rule.server, rule.times = "UpdateAsync", key, "A", 1
	world.faults:add(rule)
end

const function bank(world: World.World): number
	return (world.backend:latest("Guilds/global", "g_1") :: any).value.Data.bank
end

for _, name in { "landedThenFailed", "landedAnsweredLate", "timedOutLandedLate", "failed", "lost" } do
	Spec.test(`Once: an update whose first try {name} lands once`, function()
		const world = World.new(3)
		const server = world:server({ name = "A", players = 1 })
		const guilds = KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services })
		arm(world, "g_1", name)
		local result: any = nil
		Sim.run(world.scheduler, "A", function()
			result = guilds:update("g_1", function(data: any)
				data.bank += 100
			end)
		end, 120)
		Spec.equal(result, { ok = true, data = { bank = 100 } })
		Spec.equal(bank(world), 100)
		-- A second update is a change of its own: it lands too.
		Sim.run(world.scheduler, "A", function()
			result = guilds:update("g_1", function(data: any)
				data.bank += 100
			end)
		end, 240)
		Spec.equal(result, { ok = true, data = { bank = 200 } })
		Spec.equal(bank(world), 200)
	end)
end

Spec.test("Once: an update finds its id among others and keeps only the newest", function()
	const world = World.new(5)
	const server = world:server({ name = "A", players = 1 })
	const guilds = KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services })
	Sim.run(world.scheduler, "A", function()
		for _ = 1, Once.KEEP + 5 do
			assert(
				guilds:update("g_1", function(data: any)
					data.bank += 1
				end).ok,
				"an update landed"
			)
		end
	end, 600)
	const record = (world.backend:latest("Guilds/global", "g_1") :: any).value
	Spec.equal(record.Data.bank, Once.KEEP + 5)
	Spec.equal(#record.MetaData.KeepBlox.applied, Once.KEEP)
	-- The data the game sees has none of it.
	Sim.run(world.scheduler, "A", function()
		Spec.equal(guilds:read("g_1"), { ok = true, data = { bank = Once.KEEP + 5 } })
	end, 700)
end)

Spec.test("Once: ids are forgotten once no try of their call can land, and kept until then", function()
	const keep = 140 + Once.SKEW
	const old = { { "old", 1000 }, { "edge", 1000 + 10 } }
	Spec.equal(
		Once.note(old, "new", 1000 + keep + 10, 1000 + keep + 10, keep),
		{ { "edge", 1010 }, { "new", 1000 + keep + 10 } }
	)
	Spec.equal(Once.seen(old, "edge"), true)
	Spec.equal(Once.seen(old, "other"), false)
	Spec.equal(Once.seen("garbage", "old"), false)
	-- What is not an id is dropped, never kept or thrown on.
	Spec.equal(
		Once.note({ "x", { 7, 1000 }, { "ok", 1000 } }, "new", 1000, 1000, keep),
		{ { "ok", 1000 }, { "new", 1000 } }
	)
end)

-- Messages: one send, whatever its first try meets, is one message in the queue, stored as given.
const function queue(world: World.World): { any }
	return (world.backend:latest("Profiles/global", "u_1") :: any).value.GlobalUpdates[2]
end

for _, name in { "landedThenFailed", "landedAnsweredLate", "timedOutLandedLate", "failed", "lost" } do
	Spec.test(`Once: a message whose first try {name} is queued once`, function()
		const world = World.new(4)
		const server = world:server({ name = "A", players = 1 })
		const store = KeepBlox.store("Profiles", { template = { gifts = 0 }, services = server.services })
		arm(world, "u_1", name)
		local result: any = nil
		Sim.run(world.scheduler, "A", function()
			result = store:message("u_1", { gift = 1 })
		end, 160)
		Spec.equal(result, { ok = true })
		Spec.equal(queue(world), { { 1, { gift = 1 } } })
		-- A second send is a message of its own.
		Sim.run(world.scheduler, "A", function()
			result = store:message("u_1", { gift = 2 })
		end, 320)
		Spec.equal(result, { ok = true })
		Spec.equal(queue(world), { { 1, { gift = 1 } }, { 2, { gift = 2 } } })
	end)
end

Spec.test("Once: a message sent to a profile someone plays is handled once, and its id stays out of it", function()
	const world = World.new(6)
	const a = KeepBlox.store("Profiles", { template = { gifts = 0 }, services = world:server({ name = "A" }).services })
	const b = KeepBlox.store("Profiles", { template = { gifts = 0 }, services = world:server({ name = "B" }).services })
	local profile: any = nil
	local seen: { any } = {}
	Sim.run(world.scheduler, "B", function()
		profile = (b:load("u_1") :: any).profile
		profile:onMessage(function(message: any, processed: () -> ())
			table.insert(seen, message)
			profile.Data.gifts += message.gift
			processed()
		end)
	end, 20)
	arm(world, "u_1", "landedThenFailed")
	Sim.run(world.scheduler, "A", function()
		Spec.equal(a:message("u_1", { gift = 3 }), { ok = true })
	end, 60)
	Sim.run(world.scheduler, "B", function()
		profile:release()
	end, 120)
	Spec.equal(seen, { { gift = 3 } })
	const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(record.Data.gifts, 3)
	Spec.equal(record.GlobalUpdates[2], {})
	Spec.equal(#record.GlobalUpdates[3], 1)
end)

return nil
