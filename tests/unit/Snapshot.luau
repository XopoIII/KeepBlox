--!strict
--- Snapshots in the server heartbeat (Lease, Recover): a crash loses about one beat of play, and what
--- went with the snapshot (purchases, messages) is never granted or processed twice.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, gifts = {} }

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

const function store(world: World.World, name: string, config: { [string]: number }?): KeepBlox.Store
	return KeepBlox.store(
		"Profiles",
		{ template = TEMPLATE, services = world:server({ name = name }).services, config = config }
	)
end

-- A plays `u_1` for `seconds`, one coin a second, and dies; returns the coins played.
const function playThenCrash(world: World.World, a: KeepBlox.Store, seconds: number): number
	local played = 0
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		for _ = 1, seconds do
			world.scheduler:wait(1)
			played += 1
			result.profile.Data.coins = played
		end
	end, world.scheduler.now + seconds + 5)
	return played
end

const function crash(world: World.World, name: string)
	world.scheduler:crash(name)
	world.bus:disconnectServer(name)
end

const function reload(world: World.World, b: KeepBlox.Store): any
	local profile: any = nil
	Sim.run(world.scheduler, "B", function()
		const result = b:load("u_1")
		assert(result.ok, `B loaded ({(result :: any).reason})`)
		profile = result.profile
	end, world.scheduler.now + 120)
	return profile
end

Spec.test("Snapshot: a crash loses about one beat of play, not a renewal", function()
	for seed = 1, 10 do
		const world = World.new(seed)
		const a = store(world, "A")
		const played = playThenCrash(world, a, 100 + seed * 7)
		crash(world, "A")
		const coins = reload(world, store(world, "B")).Data.coins
		Spec.truthy(played - coins <= 5, `seed {seed}: played {played}, got {coins}`)
	end
end)

Spec.test("Snapshot: one older than the stored data is not used", function()
	const world = World.new(2)
	const a = store(world, "A")
	local saved = false
	world.scheduler:spawn(function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.coins = 5
		world.scheduler:wait(6)
		result.profile.Data.coins = 9
		result.profile:save()
		saved = true
	end, "A")
	-- The crash comes right after the save, before a beat drops the older snapshot of 5 coins.
	local running = true
	while running and not saved do
		running = world.scheduler:step()
	end
	const entry = (world.memory.maps["sorted:KB_servers"]["job-A"] :: any).value
	Spec.equal(entry.s["Profiles/u_1"].d.coins, 5, "the older snapshot is still there")
	crash(world, "A")
	Spec.equal(reload(world, store(world, "B")).Data.coins, 9)
end)

Spec.test("Snapshot: a purchase granted into it is not granted again after the crash", function()
	const world = World.new(3)
	const a = store(world, "A")
	const product = {
		keyFor = function(userId: number): string
			return `u_{userId}`
		end,
		products = {
			[1] = function(profile: any)
				profile.Data.coins += 100
			end,
		},
	}
	const decideA = a:receipts(product)
	Sim.run(world.scheduler, "A", function()
		assert((a:load("u_1") :: any).ok, "A loaded")
		-- The data store is down for A: the grant cannot be stored, but the beat carries it.
		world.faults:add({ op = "UpdateAsync", server = "A", error = "502: down" })
		Spec.equal(decideA({ PlayerId = 1, PurchaseId = "r1", ProductId = 1 }), "NotProcessedYet")
		world.scheduler:wait(6)
	end, world.scheduler.now + 60)
	crash(world, "A")
	world.faults:clear()
	const b = store(world, "B")
	const decideB = b:receipts(product)
	const profile = reload(world, b)
	Sim.run(world.scheduler, "B", function()
		Spec.equal(decideB({ PlayerId = 1, PurchaseId = "r1", ProductId = 1 }), "PurchaseGranted")
	end, world.scheduler.now + 30)
	Spec.equal(profile.Data.coins, 100, "granted once, and kept")
end)

Spec.test("Snapshot: a message processed into it is not processed again after the crash", function()
	const world = World.new(4)
	const a = store(world, "A")
	local handled = 0
	Sim.run(world.scheduler, "A", function()
		a:message("u_1", { id = "g1" })
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		world.faults:add({ op = "UpdateAsync", server = "A", error = "502: down" })
		result.profile:onMessage(function(message: any, processed: () -> ())
			result.profile.Data.gifts[message.id] = 1
			processed()
		end)
		world.scheduler:wait(6)
	end, world.scheduler.now + 60)
	crash(world, "A")
	world.faults:clear()
	const profile = reload(world, store(world, "B"))
	Sim.run(world.scheduler, "B", function()
		profile:onMessage(function(_: any, processed: () -> ())
			handled += 1
			processed()
		end)
		world.scheduler:wait(5)
	end, world.scheduler.now + 30)
	Spec.equal(profile.Data.gifts, { g1 = 1 })
	Spec.equal(handled, 0, "not delivered again")
end)

Spec.test("Snapshot: when the data turns unstorable, the last good snapshot is what gets stored", function()
	const world = World.new(5)
	const a = store(world, "A")
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.coins = 40
		world.scheduler:wait(6)
		result.profile.Data.coins = 0 / 0
		result.profile:release()
	end, world.scheduler.now + 60)
	Spec.equal(stored(world, "u_1").Data.coins, 40)
end)

Spec.test("Snapshot: a profile too large for one is written every renewFallback instead", function()
	const world = World.new(6)
	const a = store(world, "A")
	local coins = 0
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.gifts = { note = string.rep("x", 5000) }
		for second = 1, 200 do
			world.scheduler:wait(1)
			result.profile.Data.coins = second
		end
		coins = result.profile.Data.coins
	end, world.scheduler.now + 210)
	crash(world, "A")
	const got = reload(world, store(world, "B")).Data.coins
	Spec.truthy(coins - got <= 32, `played {coins}, got {got}`)
end)

return nil
