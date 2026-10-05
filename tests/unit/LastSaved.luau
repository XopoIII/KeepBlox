--!strict
--- `profile.lastSavedAt`: when the record was last written before this session took it. A game pays
--- for the time a player was away with it, so it must be the earlier session's time, never this load's.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const AWAY = 3600

const function stored(world: World.World, store: string, key: string): any
	return (world.backend:latest(`{store}/global`, key) :: any).value
end

-- One session on `store` that saves 5 coins and releases; then `AWAY` seconds pass.
const function played(world: World.World, store: KeepBlox.Store, clock: any)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_1")
		assert(result.ok, "first load")
		Spec.equal(result.profile.lastSavedAt, 0, "a key that held nothing was never saved")
		result.profile.Data.coins = 5
		result.profile:release()
		clock.wait(AWAY)
	end, world.scheduler.now + AWAY + 60)
end

Spec.test("LastSaved: a new profile says 0; the next session says when the first one last wrote", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	const clock = server.services.clock
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = server.services })
	played(world, store, clock)
	const released = stored(world, "Profiles", "u_1").MetaData.LastUpdate
	-- The release was written within the minute `played` allows before the wait, on the fake clock.
	Spec.truthy(released >= world.epoch and released < world.epoch + 60, `released at {released}`)
	local third: any = nil
	Sim.run(world.scheduler, "A", function()
		const loadedAt = clock.time()
		const second = store:load("u_1")
		assert(second.ok, "second load")
		Spec.equal(second.profile.loadCount, 2)
		Spec.equal(second.profile.lastSavedAt, released, "the first session's release, not this claim")
		Spec.equal(loadedAt - second.profile.lastSavedAt >= AWAY, true, "the time away is all there")
		const claimed = stored(world, "Profiles", "u_1").MetaData.LastUpdate
		Spec.truthy(claimed >= released + AWAY, "the claim wrote its own time into the record")
		Spec.equal(second.profile:save(), true)
		Spec.equal(second.profile.lastSavedAt, released, "this session's saves do not move it")
		second.profile:release()
		-- A load right after a release reports that release: recent, not 0 and not the older one.
		const rereleased = stored(world, "Profiles", "u_1").MetaData.LastUpdate
		third = store:load("u_1")
		assert(third.ok, "third load")
		Spec.equal(third.profile.lastSavedAt, rereleased)
		Spec.truthy(rereleased >= released + AWAY, "the second session's release, not the first's")
	end, world.scheduler.now + 60)
	Spec.equal(third.profile.loadCount, 3)
end)

Spec.test("LastSaved: a stored record with no usable LastUpdate says 0", function()
	for index, garbage in { "yesterday", false, { 1 } } :: { any } do
		const world = World.new(1)
		const server = world:server({ name = "A", players = 1 })
		const name = `Garbage{index}`
		const store = KeepBlox.store(name, { template = { coins = 0 }, services = server.services })
		played(world, store, server.services.clock)
		Sim.run(world.scheduler, "A", function()
			const raw = server.services.dataStores:GetDataStore(name)
			const record = stored(world, name, "u_1")
			-- `false` stands for a record without the field: a table cannot hold nil.
			record.MetaData.LastUpdate = if garbage == false then nil else garbage
			raw:SetAsync("u_1", record)
			const result = store:load("u_1")
			assert(result.ok, "loaded")
			Spec.equal(result.profile.Data.coins, 5, "the stored profile, not a new one")
			Spec.equal(result.profile.lastSavedAt, 0)
		end, world.scheduler.now + 60)
	end
end)

Spec.test("LastSaved: a mock store keeps the time as a real one does", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	const clock = server.services.clock
	const store = KeepBlox.store("LastSavedMock", { template = { coins = 0 }, services = server.services, mock = true })
	local releasedAt = 0
	Sim.run(world.scheduler, "A", function()
		const first = store:load("u_1")
		assert(first.ok, "first load")
		Spec.equal(first.profile.lastSavedAt, 0)
		clock.wait(100)
		releasedAt = clock.time()
		first.profile:release()
		Spec.equal(clock.time(), releasedAt, "memory answers within the second")
		clock.wait(AWAY)
		const second = store:load("u_1")
		assert(second.ok, "second load")
		Spec.equal(second.profile.lastSavedAt, releasedAt)
		Spec.equal(clock.time() - second.profile.lastSavedAt, AWAY)
	end, AWAY + 200)
	Spec.equal(releasedAt, world.epoch + 100)
end)

Spec.test("LastSaved: studio = copy reports the live profile's last write", function()
	const world = World.new(1)
	const owner = world:server({ name = "L" })
	const store = KeepBlox.store("LastSavedCopy", { template = { coins = 0 }, services = owner.services })
	Sim.run(world.scheduler, "L", function()
		const result = store:load("u_1")
		assert(result.ok, "live load")
		owner.services.clock.wait(50)
		Spec.equal(result.profile:save(), true)
	end, 100)
	const services: any = world:server({ name = "S" }).services
	services.isStudio = true
	const studio = KeepBlox.store("LastSavedCopy", { template = { coins = 0 }, services = services, studio = "copy" })
	Sim.run(world.scheduler, "S", function()
		services.clock.wait(20)
		-- The live server still holds the key, and its last write is the save above: its first renewal
		-- is 300 s away at the least.
		const live = stored(world, "LastSavedCopy", "u_1")
		Spec.truthy(live.MetaData.ActiveSession ~= nil, "the live session is still open")
		const saved = live.MetaData.LastUpdate
		Spec.truthy(saved >= world.epoch + 50 and saved < world.epoch + 100, `saved at {saved}`)
		const result = studio:load("u_1")
		assert(result.ok, "studio load")
		Spec.equal(result.profile.lastSavedAt, saved)
		Spec.truthy(services.clock.time() - saved >= 20, "earlier than this load")
	end, world.scheduler.now + 60)
end)

Spec.test("LastSaved: imported data has no earlier save here, whatever the old library recorded", function()
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	const store = KeepBlox.store("LastSavedImport", {
		template = { coins = 0 },
		services = server.services,
		import = KeepBlox.importers.DataKeep({}),
	})
	Sim.run(world.scheduler, "A", function()
		server.services.dataStores:GetDataStore("LastSavedImport"):SetAsync("u_1", {
			Data = { coins = 12 },
			Metadata = { ActiveSession = nil, LastUpdate = world.epoch - 500, Created = 0, LoadCount = 4 },
			GlobalUpdates = { Id = 0, Updates = {} },
			UserIds = { 1 },
		})
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.equal(result.profile.Data.coins, 12)
		Spec.equal(result.profile.lastSavedAt, 0)
	end, 60)
end)

return nil
