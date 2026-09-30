--!strict
--- The MemoryStore heartbeat beside the data store lock (Lease): a dead owner is known in seconds, a
--- live one hears a request without MessagingService, and an outage falls back to the lease rule.
const KeepBlox = require("@keepblox")
const Lease = require("@keepblox/Lease")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

-- Server A holds u_1 with `coins`; returns the world and A.
const function held(seed: number, coins: number, config: { [string]: number }?): (World.World, World.Server)
	const world = World.new(seed)
	const a = world:server({ name = "A", players = 1 })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = a.services, config = config })
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.coins = coins
		result.profile:save()
	end, 20)
	return world, a
end

-- Server B loads u_1; returns how long it took and the coins it got.
const function takeOver(world: World.World, name: string, config: { [string]: number }?): (number, number)
	const b = KeepBlox.store(
		"Profiles",
		{ template = TEMPLATE, services = world:server({ name = name }).services, config = config }
	)
	local took, coins = math.huge, -1
	Sim.run(world.scheduler, name, function()
		const started = world.scheduler.now
		const result = b:load("u_1")
		assert(result.ok, `{name} loaded ({(result :: any).reason})`)
		took, coins = world.scheduler.now - started, result.profile.Data.coins
	end, world.scheduler.now + 200)
	return took, coins
end

Spec.test("Lease: a crashed owner is taken over within its beat's expiry, not the lease's 35 s", function()
	for seed = 1, 10 do
		const world, a = held(seed, 5)
		a:crash()
		const took, coins = takeOver(world, "B")
		Spec.truthy(took < 16, `seed {seed}: took {took} s`)
		Spec.equal(coins, 5)
	end
end)

Spec.test("Lease: an owner cut off from MessagingService hands over at its next beat, with a final save", function()
	-- The owner renews its data store lease only every 300 s here, so only the beat can carry the request.
	for seed = 1, 8 do
		const world = held(seed, 9, { renew = 300, death = 700 })
		world.bus.partitioned.A = true
		const took, coins = takeOver(world, "B")
		Spec.truthy(took < 9, `seed {seed}: took {took} s`)
		Spec.equal(coins, 9, "the owner's data came with the hand-over")
		Spec.equal(stored(world, "u_1").MetaData.KeepBlox.memory, true)
	end
end)

Spec.test("Lease: with MemoryStore down, the lease rule still takes over a crashed owner, safely", function()
	-- The fallback rule at a 15 s renewal (35 s death), so it shows within the spec's time.
	const fallback = { renew = 15, death = 35 }
	const world, a = held(4, 7, fallback)
	a:crash()
	world.faults:add({ op = "MemoryStoreGetAsync", error = "InternalError: memory store unavailable" })
	world.faults:add({ op = "MemoryStoreUpdateAsync", error = "InternalError: memory store unavailable" })
	const took, coins = takeOver(world, "B", fallback)
	Spec.truthy(took >= 30 and took < 60, `took {took} s (the data store rule)`)
	Spec.equal(coins, 7)
end)

Spec.test("Lease: a live owner's beat keeps a quiet edit out; a dead one's does not", function()
	const world, a = held(5, 1)
	const other = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	local live: any = nil
	Sim.run(world.scheduler, "B", function()
		live = other:edit("u_1", function(data: any)
			data.coins += 1
		end)
	end, world.scheduler.now + 60)
	Spec.equal(live, { ok = false, reason = "inUse" })
	a:crash()
	local dead: any = nil
	Sim.run(world.scheduler, "B", function()
		dead = other:edit("u_1", function(data: any)
			data.coins += 1
		end)
	end, world.scheduler.now + 120)
	Spec.equal(dead, { ok = true, data = { coins = 2 } })
end)

Spec.test("Lease: a live owner whose beats hang is not taken for dead", function()
	-- Its beat stands still for newcomers long before its own call times out (callTimeout, 20 s). The
	-- owner withdraws its beat from the record once none has landed soon after being sent, and a
	-- takeover on the beat's word lands only while the record still vouches for it (PaxosLease
	-- Revisited, arXiv 2609.14640: the holder must give up before the other side may conclude).
	for seed = 1, 8 do
		const world = held(seed, 1)
		world.faults:add({ op = "MemoryStoreUpdateAsync", server = "A", hang = true })
		const other =
			KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
		local edited: any = nil
		Sim.run(world.scheduler, "B", function()
			edited = other:edit("u_1", function(data: any)
				data.coins += 1
			end)
		end, world.scheduler.now + 150)
		Spec.equal(edited and edited.ok, false, `seed {seed}: the edit took the key from a live owner`)
		const record = stored(world, "u_1")
		Spec.equal(record.MetaData.ActiveSession[2], "job-A", `seed {seed}: A still holds the key`)
		Spec.equal(record.Data.coins, 1, `seed {seed}`)
	end
end)

-- A newcomer that just looked at the beat while waiting reuses that verdict right after trying the data
-- store, and only then: a verdict a second old, a dead one, or one before the owner was asked is looked
-- at again.
Spec.test("Lease: a verdict is reused for a second after the beat was looked at, never longer", function()
	local now = 100
	const context: any = { services = { clock = {
		now = function(): number
			return now
		end,
	} } }
	const watch: Lease.Watch = { asked = true, loadCount = 1, lookedAt = 100, verdict = "alive" }
	Spec.equal(Lease.recent(context, watch), "alive")
	now = 100.9
	Spec.equal(Lease.recent(context, watch), "alive")
	now = 101
	Spec.equal(Lease.recent(context, watch), nil, "a second old")
	now = 100.5
	watch.verdict = "dead"
	Spec.equal(Lease.recent(context, watch), nil, "dead")
	watch.verdict, watch.asked = "pending", false
	Spec.equal(Lease.recent(context, watch), nil, "not asked yet")
	Spec.equal(Lease.recent(context, { asked = true, loadCount = 1 }), nil, "never looked at")
end)

return nil
