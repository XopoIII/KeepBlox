--!strict
--- Writes that replace what is stored land late without harm (issue 41, src/Once.luau). A call the
--- library stopped waiting for keeps running (see Call), and may land after a newer write: a session's
--- save must not put older data over newer, a claim must not start its load over or take back a key its
--- load let go, and a heartbeat must not put older snapshots over newer ones. Each stands beside the
--- write that follows it, which must still land.
const Errors = require("@fakes/Errors")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

const function stored(world: World.World): any
	return (world.backend:latest("Profiles/global", "u_1") :: any).value
end

-- A's next data store call on u_1 waits 30 s, past its 20 s deadline, then runs.
const function hold(world: World.World)
	world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", delay = 30, times = 1 })
end

Spec.test("OnceLate: a save that times out and lands after a newer one leaves the newer data", function()
	const world = World.new(7)
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	local profile: any = nil
	local first, second, third = nil, nil, nil
	Sim.run(world.scheduler, "A", function()
		profile = (store:load("u_1") :: any).profile
		profile.Data.coins = 1
		hold(world)
		first = profile:save()
		profile.Data.coins = 2
		second = profile:save()
	end, 25)
	Spec.equal({ first, second }, { false, true })
	Spec.equal(stored(world).Data.coins, 2)
	-- The late save runs at 30 s.
	Sim.run(world.scheduler, "A", function()
		world.scheduler:wait(20)
	end, 50)
	Spec.equal(stored(world).Data.coins, 2)
	Spec.equal(profile:isActive(), true)
	-- The next save lands as before.
	Sim.run(world.scheduler, "A", function()
		profile.Data.coins = 3
		third = profile:save()
	end, 60)
	Spec.equal(third, true)
	Spec.equal(stored(world).Data.coins, 3)
end)

Spec.test("OnceLate: a claim that times out and lands after its retry leaves the load's session be", function()
	const world = World.new(8)
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	local profile: any = nil
	hold(world)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, `A loaded ({(result :: any).reason})`)
		profile = result.profile
	end, 25)
	Spec.equal(stored(world).MetaData.SessionLoadCount, 1)
	local saved = nil
	Sim.run(world.scheduler, "A", function()
		world.scheduler:wait(20)
		profile.Data.coins = 4
		saved = profile:save()
	end, 60)
	Spec.equal(saved, true)
	Spec.equal(profile:isActive(), true)
	Spec.equal(stored(world).MetaData.SessionLoadCount, 1)
	Spec.equal(stored(world).Data.coins, 4)
end)

Spec.test("OnceLate: a claim that lands after its load let the key go takes nothing", function()
	const world = World.new(9)
	const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	hold(world)
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, `A loaded ({(result :: any).reason})`)
		result.profile:release()
	end, 25)
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
	Sim.run(world.scheduler, "A", function()
		world.scheduler:wait(15)
	end, 45)
	Spec.equal(stored(world).MetaData.ActiveSession, nil)
	-- The next load, on another server, takes the key at once.
	local took = math.huge
	Sim.run(world.scheduler, "B", function()
		const started = world.scheduler.now
		const result = b:load("u_1")
		assert(result.ok, `B loaded ({(result :: any).reason})`)
		took = world.scheduler.now - started
	end, 100)
	Spec.truthy(took < 2, `B took {took} s`)
	Spec.equal(stored(world).MetaData.SessionLoadCount, 2)
end)

Spec.test("OnceLate: a heartbeat that lands after a newer one leaves the newer snapshot", function()
	-- Beats every second. The data store takes none of A's writes from 10 s on, so the snapshots in
	-- MemoryStore are all a crash leaves of the play since.
	const world = World.new(10)
	const a = world:server({ name = "A", players = 1 })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = a.services, config = { heartbeat = 1 } })
	local profile: any = nil
	Sim.run(world.scheduler, "A", function()
		profile = (store:load("u_1") :: any).profile
	end, 10)
	world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = Errors.rejected() })
	-- The next beat (by 11 s) takes a snapshot of 1 coin and waits 30 s on its way: it runs at about 41 s.
	-- The one after it, sent when the first timed out (about 31 s), carries 2 coins and lands. From 33 s
	-- on no beat lands, so nothing but the late one writes over the snapshot of 2 coins.
	Sim.run(world.scheduler, "A", function()
		profile.Data.coins = 1
		world.faults:add({ op = "MemoryStoreUpdateAsync", key = "job-A", server = "A", delay = 30, times = 1 })
		world.scheduler:wait(1.5)
		profile.Data.coins = 2
		world.scheduler:wait(33 - world.scheduler.now)
		world.faults:add({ op = "MemoryStoreUpdateAsync", key = "job-A", server = "A", error = "Throttled" })
	end, 43)
	Spec.equal(stored(world).Data.coins, 0)
	a:crash()
	world.faults:clear()
	const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	local coins = -1
	Sim.run(world.scheduler, "B", function()
		const result = b:load("u_1")
		assert(result.ok, `B loaded ({(result :: any).reason})`)
		coins = result.profile.Data.coins
	end, 200)
	Spec.equal(coins, 2)
end)

-- A try held far longer than its call may run (900 s): its id is forgotten by then, at the next
-- update past `lifetime + SKEW` (740 s), and the transform's own deadline keeps it from landing.
Spec.test("OnceLate: a try that runs after its call's time changes nothing, though its id is forgotten", function()
	const world = World.new(11)
	const server = world:server({ name = "A", players = 1 })
	const guilds = KeepBlox.shared("Guilds", { template = { bank = 0 }, services = server.services })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = server.services })
	world.faults:add({ op = "UpdateAsync", key = "g_1", server = "A", delay = 900, times = 1 })
	world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", delay = 900, times = 1 })
	const function add(): any
		return guilds:update("g_1", function(data: any)
			data.bank += 100
		end)
	end
	Sim.run(world.scheduler, "A", function()
		Spec.equal(add(), { ok = true, data = { bank = 100 } })
		Spec.equal(store:message("u_1", { gift = 1 }), { ok = true })
		world.scheduler:wait(800 - world.scheduler.now)
		Spec.equal(add(), { ok = true, data = { bank = 200 } })
		Spec.equal(store:message("u_1", { gift = 2 }), { ok = true })
	end, 1000)
	const guild = (world.backend:latest("Guilds/global", "g_1") :: any).value
	Spec.equal(guild.Data.bank, 200)
	Spec.equal(#guild.MetaData.KeepBlox.applied, 1)
	const queued = stored(world).GlobalUpdates
	Spec.equal(queued[2], { { 1, { gift = 1 } }, { 2, { gift = 2 } } })
	Spec.equal(#queued[3], 1)
end)

return nil
