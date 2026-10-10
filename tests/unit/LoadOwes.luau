--!strict
--- A load that gives a key back without having stored its dead owner's last beat leaves the beat to
--- the next load (src/Owed.luau, src/LetGo.luau, src/Recover.luau, src/Enter.luau; issue 36). Before
--- 0.6.10 the key was freed with no previous owner to recover from, and that beat was lost.
---
--- The beat a server cannot apply for want of a codec is in tests/unit/LoadThrows.luau.
const GiveUpRig = require("./GiveUpRig")
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene

const UNSTORED = "u_1: a newer snapshot was found but could not be stored; the stored data is used"

-- Server B held "u_1" with 5 coins stored and a sixth only in its beats, and died (or the world
-- `before` makes); A's store takes `options`. `onLanded` runs once, as the write that makes the key
-- A's commits.
const function scene(
	seed: number,
	options: { [string]: any }?,
	onLanded: (scene: Scene) -> (),
	before: ((world: World.World) -> ())?
): Scene
	const made = LoadRig.scene(seed, before or function(world: World.World)
		LoadRig.owner(world):crash()
	end, options)
	local landed = false
	made.world.backend:observe(function(event: any)
		const session = event.version.value.MetaData.ActiveSession
		if not landed and event.writer == "A" and session ~= nil and session[2] == made.server.services.jobId then
			landed = true
			onLanded(made)
		end
	end)
	return made
end

-- The note in the stored record of "u_1", and whether the key is free.
const function noted(world: World.World): (any, boolean)
	const record = LoadRig.stored(world)
	return record.MetaData.KeepBlox.owed, record.MetaData.ActiveSession == nil
end

Spec.test("Load owes: a beat the data store refused as the server closed is left to the next server", function()
	const made = scene(5, nil, function(landed: Scene)
		-- The store takes no write of the beat, and the server begins to close: no second try.
		landed.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = "503: down", times = 1 })
		landed.world.scheduler:spawn(landed.server.closing[1], "A")
	end)
	const scheduler = made.world.scheduler
	local answer: any = nil
	Sim.run(scheduler, "A", function()
		answer = made.store:load("u_1")
	end, scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "closing" })
	Spec.equal(made.errors, { UNSTORED })
	const stored = LoadRig.stored(made.world)
	Spec.equal(stored.Data, { coins = 5 }, "the beat was not stored")
	Spec.equal({ noted(made.world) }, { { j = "job-B", c = 1, q = 0, at = 2 }, true } :: { any })
	-- The next server stores the beat before it plays, and the note is used up.
	GiveUpRig.next(made, "C", 6, GiveUpRig.FREE, "after A closed")
	Spec.equal({ noted(made.world) }, { nil, true } :: { any })
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Load owes: a beat MemoryStore gave no answer about is left to the next server", function()
	const player = { left = false }
	const made = scene(5, nil, function(landed: Scene)
		player.left = true
		landed.world.faults:add({ op = "MemoryStoreGetAsync", server = "A", error = "InternalError", times = 1 })
	end)
	const scheduler = made.world.scheduler
	local answer: any = nil
	Sim.run(scheduler, "A", function()
		answer = made.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		Spec.equal(LoadRig.heldBy(made.world, made.server), false, "A holds the key after its answer")
	end, scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	Spec.equal(made.errors, {})
	Spec.equal({ noted(made.world) }, { { j = "job-B", c = 1, q = 0, at = 2 }, true } :: { any })
	GiveUpRig.next(made, "C", 6, GiveUpRig.FREE, "after the answer")
	Spec.equal({ noted(made.world) }, { nil, true } :: { any })
end)

Spec.test("Load owes: a note whose beat is gone, or was stored after all, costs the next load nothing", function()
	-- MemoryStore answered that B left no newer snapshot: nothing is owed, and no note is left.
	const player = { left = false }
	const none = scene(11, nil, function()
		player.left = true
	end, function(world: World.World)
		const store, server = LoadRig.store(world, "B")
		Sim.run(world.scheduler, "B", function()
			const result = store:load("u_1")
			assert(result.ok, "B loaded")
			result.profile.Data.coins = 5
			assert(result.profile:save(), "B saved")
		end, 20)
		server:crash()
	end)
	local answer: any = nil
	Sim.run(none.world.scheduler, "A", function()
		answer = none.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
	end, none.world.scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	Spec.equal({ noted(none.world) }, { nil, true } :: { any })
	GiveUpRig.next(none, "C", 5, GiveUpRig.FREE, "no beat")
	-- A note left for a beat whose entry has expired since (`snapshotTtl`, 900 s): the stored data.
	const left = { left = false }
	const expired = scene(5, nil, function(landed: Scene)
		left.left = true
		landed.world.faults:add({ op = "MemoryStoreGetAsync", server = "A", error = "InternalError", times = 1 })
	end)
	Sim.run(expired.world.scheduler, "A", function()
		expired.store:load("u_1", {
			cancel = function(): boolean
				return left.left
			end,
		})
		expired.world.scheduler:wait(1000)
	end, expired.world.scheduler.now + 1100)
	Spec.equal({ noted(expired.world) }, { { j = "job-B", c = 1, q = 0, at = 2 }, true } :: { any })
	GiveUpRig.next(expired, "C", 5, GiveUpRig.FREE, "the beat expired")
	Spec.equal({ noted(expired.world) }, { nil, true } :: { any })
	Spec.equal(expired.errors, {})
end)

Spec.test("Load owes: a load that fails after its beat could not be stored tries the beat again", function()
	-- The store refuses the beat until the load stops trying; the load goes on from the stored data
	-- and fails at its migration. Undoing it stores the beat after all, against the data as claimed.
	-- The profile is over `snapshotBytes`, so the beat holds edits, which apply only to the data
	-- they were made against: the migration's own changes must not be in it.
	const template = { coins = 0, text = string.rep("a", 3000) }
	local made: Scene
	made = scene(5, {
		template = template,
		config = { loadTimeout = 20 },
		version = 1,
		migrations = {
			function(data: any)
				data.coins += 1000
				error("no way up", 0)
			end,
		},
	}, function(landed: Scene)
		landed.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = "503: down" })
	end, function(world: World.World)
		const store, server = LoadRig.store(world, "B", { template = template })
		Sim.run(world.scheduler, "B", function()
			const result = store:load("u_1")
			assert(result.ok, "B loaded")
			result.profile.Data.coins = 5
			assert(result.profile:save(), "B saved")
			result.profile.Data.coins = 6
		end, 20)
		server:crash()
	end)
	made.options = { template = template }
	made.store.onError:connect(function(_: string, message: string)
		if string.find(message, "could not be stored", 1, true) then
			made.world.faults:clear()
		end
	end)
	const scheduler = made.world.scheduler
	local answer: any = nil
	Sim.run(scheduler, "A", function()
		answer = made.store:load("u_1")
		Spec.equal(LoadRig.heldBy(made.world, made.server), false, "A holds the key after its answer")
	end, scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "migration" })
	Spec.equal(made.errors[1], UNSTORED)
	Spec.equal(#made.errors, 2)
	Spec.equal(string.find(made.errors[2], "no way up", 1, true) ~= nil, true, made.errors[2])
	Spec.equal(LoadRig.stored(made.world).Data.coins, 6, "the beat, stored by the undoing")
	Spec.equal({ noted(made.world) }, { nil, true } :: { any })
	GiveUpRig.next(made, "C", 6, GiveUpRig.FREE, "after the answer")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Load owes: a restore of the key drops the note with the data it was played on", function()
	const player = { left = false }
	const made = scene(5, nil, function(landed: Scene)
		player.left = true
		landed.world.faults:add({ op = "MemoryStoreGetAsync", server = "A", error = "InternalError", times = 1 })
	end)
	const scheduler = made.world.scheduler
	Sim.run(scheduler, "A", function()
		made.store:load("u_1", {
			cancel = function(): boolean
				return player.left
			end,
		})
		Spec.equal({ noted(made.world) }, { { j = "job-B", c = 1, q = 0, at = 2 }, true } :: { any })
		const version = made.store:versions("u_1")[1].version
		Spec.equal(made.store:restore("u_1", version), { ok = true, purchasesSince = {} })
	end, scheduler.now + 60)
	Spec.equal({ noted(made.world) }, { nil, true } :: { any })
	-- The restored data is what the next server plays on: B's beat does not come back over it.
	GiveUpRig.next(made, "C", 5, GiveUpRig.FREE, "after the restore")
end)

Spec.test("Load owes: a key with an unfinished trade owes nothing of its last owner", function()
	-- A profile in a trade has no snapshot: the session a cancelled load opens, settles and releases
	-- leaves no note of the server that died in the trade.
	const made = LoadScenes[5].build()
	Spec.equal(LoadScenes[5].name, "a key with a trade its last server did not finish")
	const scheduler = made.world.scheduler
	const caller = LoadRig.start(made)
	scheduler:cancel(caller)
	Sim.run(scheduler, "A", function()
		scheduler:wait(30)
	end, scheduler.now + 40)
	Spec.equal({ noted(made.world) }, { nil, true } :: { any })
	Spec.equal(LoadRig.stored(made.world).Data.coins, 400)
	Spec.equal(made.errors, {})
end)

return nil
