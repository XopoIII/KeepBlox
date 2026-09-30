--!strict
--- Snapshots of large profiles (Snapshots, Recover): a profile over `snapshotBytes` carries its edits since
--- it was last stored, so a crash loses about one beat of it too, not a `renewFallback` interval; edits
--- are applied only to the data they were made against.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, gifts = {}, things = {} }

-- About 9 KB stored: fifty things, as a player's base holds them.
const function things(): { any }
	const out = {}
	for index = 1, 50 do
		table.insert(
			out,
			{ species = "Crab", tier = "Rare", roll = index / 7, x = index * 1.5, planted = 1790000000 + index }
		)
	end
	return out
end

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

const function store(world: World.World, name: string): KeepBlox.Store
	return KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = name }).services })
end

const function entry(world: World.World): any
	return (world.memory.maps["sorted:KB_servers"]["job-A"] :: any).value
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

-- A loads a large profile, saves it, then plays `seconds`, one coin a second; returns the coins played.
const function playLarge(world: World.World, a: KeepBlox.Store, seconds: number, each: ((any, number) -> ())?): number
	local played = 0
	const hook: (any, number) -> () = each or function(_: any, _: number) end
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.things = things()
		result.profile:save()
		for second = 1, seconds do
			world.scheduler:wait(1)
			played = second
			result.profile.Data.coins = second
			hook(result.profile, second)
		end
	end, world.scheduler.now + seconds + 5)
	return played
end

Spec.test("SnapshotDelta: a large profile loses about one beat of play to a crash, not a renewal", function()
	for seed = 1, 10 do
		const world = World.new(seed)
		const played = playLarge(world, store(world, "A"), 100 + seed * 7)
		const beat = entry(world)
		Spec.truthy(beat.x["Profiles/u_1"] ~= nil, `seed {seed}: no edits in the beat`)
		Spec.equal(beat.s["Profiles/u_1"], nil, `seed {seed}: the whole profile in the beat`)
		crash(world, "A")
		const profile = reload(world, store(world, "B"))
		Spec.truthy(played - profile.Data.coins <= 5, `seed {seed}: played {played}, got {profile.Data.coins}`)
		Spec.equal(profile.Data.things, things(), `seed {seed}: the things`)
	end
end)

Spec.test("SnapshotDelta: things added and removed between writes come back after a crash", function()
	const world = World.new(4)
	const played = playLarge(world, store(world, "A"), 40, function(profile: any, second: number)
		if second == 20 then
			table.remove(profile.Data.things, 1)
			table.insert(profile.Data.things, { species = "Moth", tier = "Epic", roll = 0.5, x = 1, planted = 1 })
			profile.Data.gifts.g1 = true
		end
	end)
	crash(world, "A")
	const profile = reload(world, store(world, "B"))
	const expected = things()
	table.remove(expected, 1)
	table.insert(expected, { species = "Moth", tier = "Epic", roll = 0.5, x = 1, planted = 1 })
	Spec.truthy(played - profile.Data.coins <= 5, `played {played}, got {profile.Data.coins}`)
	Spec.equal(profile.Data.things, expected)
	Spec.equal(profile.Data.gifts, { g1 = true })
end)

Spec.test("SnapshotDelta: edits made against other data than the record's are not used", function()
	const world = World.new(3)
	playLarge(world, store(world, "A"), 30)
	crash(world, "A")
	const snapshot = entry(world).x["Profiles/u_1"]
	snapshot.b = "0000000000000000"
	const b = store(world, "B")
	const reports = {}
	b.onError:connect(function(_: string, message: string)
		table.insert(reports, message)
	end)
	const profile = reload(world, b)
	Spec.equal(profile.Data.coins, stored(world, "u_1").Data.coins)
	Spec.equal(profile.Data.coins, 0, "the coins as stored with the things")
	Spec.equal(reports, { "a newer snapshot was found but was made against other data; the stored data is used" })
end)

Spec.test("SnapshotDelta: a large profile whose edits do not fit is written every renewFallback", function()
	const world = World.new(6)
	const played = playLarge(world, store(world, "A"), 200, function(profile: any, second: number)
		profile.Data.gifts = { note = string.rep(tostring(second % 10), 2000) }
	end)
	Spec.equal(entry(world).x["Profiles/u_1"], nil, "edits over snapshotBytes in the beat")
	Spec.equal(entry(world).s["Profiles/u_1"], nil, "the whole profile in the beat")
	crash(world, "A")
	const got = reload(world, store(world, "B")).Data.coins
	Spec.truthy(played - got <= 32, `played {played}, got {got}`)
end)

Spec.test("SnapshotDelta: a purchase granted into a large profile's edits is not granted again", function()
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
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		result.profile.Data.things = things()
		result.profile:save()
		world.faults:add({ op = "UpdateAsync", server = "A", error = "502: down" })
		Spec.equal(decideA({ PlayerId = 1, PurchaseId = "r1", ProductId = 1 }), "NotProcessedYet")
		world.scheduler:wait(6)
	end, world.scheduler.now + 60)
	Spec.truthy(entry(world).x["Profiles/u_1"] ~= nil, "no edits in the beat")
	crash(world, "A")
	world.faults:clear()
	const b = store(world, "B")
	const decideB = b:receipts(product)
	const profile = reload(world, b)
	Sim.run(world.scheduler, "B", function()
		Spec.equal(decideB({ PlayerId = 1, PurchaseId = "r1", ProductId = 1 }), "PurchaseGranted")
	end, world.scheduler.now + 30)
	Spec.equal(profile.Data.coins, 100, "granted once, and kept")
	Spec.equal(#profile.Data.things, 50)
end)

return nil
