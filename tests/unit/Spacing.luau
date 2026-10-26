--!strict
--- Write spacing: Roblox takes one write to a key about every 6 seconds and queues the rest, so a
--- session leaves `writeSpacing` between its writes to its key whenever the write can wait. A message
--- sent from the server that holds the key, and its processing, are writes that can.
const Config = require("@keepblox/Config")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const SPACING = Config.DEFAULT.writeSpacing
const STORE = "Profiles/global"

type Rig = { world: World.World, store: KeepBlox.Store<any>, writes: { number }, errors: { string } }

-- Server A's store, and the time (scheduler seconds) of every write that lands on "u_1".
const function rig(seed: number, config: { [string]: any }?): Rig
	const world = World.new(seed)
	const services = world:server({ name = "A" }).services
	const store = KeepBlox.store("Profiles", { template = { gifts = {} }, services = services, config = config :: any })
	const writes: { number } = {}
	world.backend:observe(function(event)
		if event.store == STORE and event.key == "u_1" then
			table.insert(writes, world.scheduler.now)
		end
	end)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	return { world = world, store = store, writes = writes, errors = errors }
end

-- Counts each gift its handler takes; `seen` counts the calls.
const function gifted(profile: any, seen: { n: number })
	profile:onMessage(function(message: any, processed: () -> ())
		seen.n += 1
		profile.Data.gifts[message.id] = (profile.Data.gifts[message.id] or 0) + 1
		processed()
	end)
end

-- The gaps between consecutive writes from the `from`-th on.
const function gaps(writes: { number }, from: number): { number }
	const found = {}
	for index = from + 1, #writes do
		table.insert(found, writes[index] - writes[index - 1])
	end
	return found
end

const function stored(world: World.World): any
	return (world.backend:latest(STORE, "u_1") :: any).value
end

Spec.test("Spacing: messages sent where the key is held, then processed, write the key spaced apart", function()
	const scene = rig(1)
	const seen = { n = 0 }
	Sim.run(scene.world.scheduler, "A", function()
		const result = scene.store:load("u_1")
		assert(result.ok, "loaded")
		gifted(result.profile, seen)
		scene.world.scheduler:wait(2)
		-- Two sends, a second apart: the saves that bring them in and store their effect are one each.
		Spec.equal(scene.store:message("u_1", { id = "g1" }), { ok = true })
		scene.world.scheduler:wait(1)
		Spec.equal(scene.store:message("u_1", { id = "g2" }), { ok = true })
		scene.world.scheduler:wait(4 * SPACING)
		Spec.equal(seen.n, 2)
		const record = stored(scene.world)
		Spec.equal(record.Data.gifts, { g1 = 1, g2 = 1 })
		Spec.equal(record.GlobalUpdates[2], {})
		result.profile:release()
	end, 60)
	-- The claim, the two sends, the save that took the messages in, the one that stored their effect,
	-- and the release.
	Spec.equal(#scene.writes, 6)
	-- The game's two sends go when it asks; every write of the session's own leaves the spacing.
	const apart = gaps(scene.writes, 3)
	for index = 1, 2 do
		Spec.truthy(apart[index] >= SPACING, `write {index + 3} came {apart[index]} s after the one before`)
	end
	Spec.equal(scene.errors, {})
end)

Spec.test("Spacing: without it, the same messages write the key within a couple of seconds", function()
	const scene = rig(1, { writeSpacing = 0.5 })
	const seen = { n = 0 }
	Sim.run(scene.world.scheduler, "A", function()
		const result = scene.store:load("u_1")
		assert(result.ok, "loaded")
		gifted(result.profile, seen)
		scene.world.scheduler:wait(2)
		scene.store:message("u_1", { id = "g1" })
		scene.world.scheduler:wait(4 * SPACING)
		Spec.equal(stored(scene.world).Data.gifts, { g1 = 1 })
		result.profile:release()
	end, 60)
	Spec.equal(seen.n, 1)
	-- The claim, the send, the save that took the message in, the one that stored its effect, the release.
	Spec.equal(#scene.writes, 5)
	const apart = gaps(scene.writes, 2)
	Spec.truthy(apart[1] < SPACING and apart[2] < SPACING, `the session wrote {apart[1]} s and {apart[2]} s apart`)
end)

Spec.test("Spacing: a save the game asks for, and a release, do not wait for it", function()
	const scene = rig(2)
	local sentAt, savedAt, releasedAt = 0, 0, 0
	Sim.run(scene.world.scheduler, "A", function()
		const result = scene.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		scene.store:message("u_1", { id = "g1" })
		sentAt = scene.world.scheduler.now
		profile.Data.gifts.saved = 1
		Spec.equal(profile:save(), true)
		savedAt = scene.world.scheduler.now
		profile.Data.gifts.released = 1
		profile:release()
		releasedAt = scene.world.scheduler.now
	end, 60)
	Spec.truthy(savedAt - sentAt < 1, `the save came {savedAt - sentAt} s after the send`)
	-- The release answers before its write lands; the write itself is the record's last.
	Spec.equal(#scene.writes, 4)
	Spec.truthy(scene.writes[4] - sentAt < SPACING, `the release landed {scene.writes[4] - sentAt} s after the send`)
	Spec.truthy(releasedAt - sentAt < SPACING)
	const record = stored(scene.world)
	Spec.equal(record.Data.gifts, { saved = 1, released = 1 })
	Spec.equal(record.MetaData.ActiveSession, nil)
end)

Spec.test("Spacing: a message waiting when the key is loaded is stored a spacing after the claim", function()
	const scene = rig(3)
	const seen = { n = 0 }
	Sim.run(scene.world.scheduler, "A", function()
		scene.store:message("u_1", { id = "g1" })
		const result = scene.store:load("u_1")
		assert(result.ok, "loaded")
		gifted(result.profile, seen)
		scene.world.scheduler:wait(SPACING + 3)
		const record = stored(scene.world)
		Spec.equal(record.Data.gifts, { g1 = 1 })
		Spec.equal(record.GlobalUpdates[2], {})
		result.profile:release()
	end, 60)
	Spec.equal(seen.n, 1)
	-- The send, the claim, the save that stored the effect, and the release.
	Spec.equal(#scene.writes, 4)
	Spec.truthy(scene.writes[3] - scene.writes[2] >= SPACING, `{scene.writes[3] - scene.writes[2]} s after the claim`)
end)

-- The owner's record must stop vouching for its beat before a newcomer could judge the beat dead (see
-- Upkeep.beat): that write does not wait. A spacing as long as the renewal leaves it the only write
-- that could land in time.
Spec.test("Spacing: an owner whose beats stop landing stops vouching for them at once, though it just wrote", function()
	for seed = 1, 8 do
		const scene = rig(seed, { writeSpacing = 300 })
		Sim.run(scene.world.scheduler, "A", function()
			const result = scene.store:load("u_1")
			assert(result.ok, "A loaded")
			result.profile.Data.gifts.kept = 1
			assert(result.profile:save(), "A saved")
		end, 20)
		Spec.equal(stored(scene.world).MetaData.KeepBlox.memory, true, `seed {seed}: the record vouches`)
		scene.world.faults:add({ op = "MemoryStoreUpdateAsync", server = "A", hang = true })
		const other = KeepBlox.store(
			"Profiles",
			{ template = { gifts = {} }, services = scene.world:server({ name = "B" }).services }
		)
		local edited: any = nil
		Sim.run(scene.world.scheduler, "B", function()
			edited = other:edit("u_1", function(data: any)
				data.gifts.taken = 1
			end)
		end, scene.world.scheduler.now + 150)
		Spec.equal(edited, { ok = false, reason = "inUse" }, `seed {seed}`)
		const record = stored(scene.world)
		Spec.equal(record.MetaData.ActiveSession[2], "job-A", `seed {seed}: A still holds the key`)
		Spec.equal(record.MetaData.KeepBlox.memory, nil, `seed {seed}: the record stopped vouching`)
		Spec.equal(record.Data.gifts, { kept = 1 }, `seed {seed}`)
	end
end)

-- Beside it: with the beat landing, nothing asks for a write, and the spacing holds every other one off.
Spec.test("Spacing: an owner whose beats land writes nothing more while the spacing lasts", function()
	const scene = rig(1, { writeSpacing = 300 })
	Sim.run(scene.world.scheduler, "A", function()
		const result = scene.store:load("u_1")
		assert(result.ok, "A loaded")
		assert(result.profile:save(), "A saved")
		scene.store:message("u_1", { id = "g1" })
	end, 300)
	-- The claim, the save and the send: the message waits in the record for the spacing to pass.
	Spec.equal(#scene.writes, 3)
	Spec.equal(stored(scene.world).MetaData.KeepBlox.memory, true)
end)

return nil
