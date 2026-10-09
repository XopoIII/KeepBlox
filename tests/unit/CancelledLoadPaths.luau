--!strict
--- Beside a cancelled `store:load` (tests/unit/CancelledLoad.luau): what a load nobody cancels still
--- does, what a later load of the key meets, a load that throws, and the shutdown (src/Open.luau,
--- src/Apart.luau, src/Settle.luau, src/Upkeep.luau; issue 31).
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene

Spec.test("Cancelled load: a load nobody cancels starts in its caller's turn and answers as it did", function()
	const scene = LoadRig.scene(3)
	const scheduler = scene.world.scheduler
	const spent = scene.server.budget.spent
	Spec.equal(scene.world.memory.spent.A, 1, "the store's first beat is on its way")
	const _, first = LoadRig.start(scene)
	-- The load's first request left in the caller's own turn (a beat of its own, as none has landed).
	Spec.equal(scene.world.memory.spent.A, 2)
	Spec.equal(first.result, nil)
	-- A second load of the key while the first is in flight, its caller still there, gets "open" at
	-- once: it does not wait for the first, and asks for nothing.
	const started = scheduler.now
	const _, second = LoadRig.start(scene)
	Spec.equal(second.result, { ok = false, reason = "open" })
	Spec.equal(scheduler.now, started)
	scheduler:run(10)
	assert(first.result and first.result.ok, "the first loaded")
	const profile = first.result.profile
	Spec.equal(profile.Data, { coins = 0 })
	Spec.equal(profile:isActive(), true)
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), true)
	-- One claim: one request, which a data store counts as a read and a write.
	Spec.equal({ spent.StandardRead, spent.StandardWrite }, { 1, 1 })
	-- And "open" again while the session lives.
	const _, third = LoadRig.start(scene)
	Spec.equal(third.result, { ok = false, reason = "open" })
	Spec.equal({ spent.StandardRead, spent.StandardWrite }, { 1, 1 })
	Spec.equal(scene.errors, {})
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Cancelled load: `cancel` and a closing store still answer the caller that waits", function()
	-- The key is held by a server that neither answers nor is dead yet, so the load waits.
	const function waiting(): (Scene, { result: any }, { left: boolean })
		const scene = LoadRig.scene(4, function(world: World.World)
			LoadRig.owner(world)
			world.faults:add({ op = "UpdateAsync", server = "B", hang = true })
			world.faults:add({ op = "UpdateSortedMapAsync", server = "B", hang = true })
		end)
		const player = { left = false }
		const _, answer = LoadRig.start(scene, {
			cancel = function(): boolean
				return player.left
			end,
		})
		scene.world.scheduler:run(scene.world.scheduler.now + 3)
		Spec.equal(answer.result, nil, "still waiting for the key")
		return scene, answer, player
	end
	const left, cancelled, player = waiting()
	player.left = true
	left.world.scheduler:run(left.world.scheduler.now + 6)
	Spec.equal(cancelled.result, { ok = false, reason = "cancelled" })
	Spec.equal(LoadRig.heldBy(left.world, left.server), false)
	const closed, closing = waiting()
	Sim.run(closed.world.scheduler, "A", function()
		closed.server.closing[1]()
		-- The close waited for the load in flight: it had answered when the close returned.
		Spec.equal(closing.result, { ok = false, reason = "closing" })
	end, closed.world.scheduler.now + 30)
	Spec.equal(LoadRig.heldBy(closed.world, closed.server), false)
end)

Spec.test("Cancelled load: a second load of a key whose first caller was cancelled waits, and gets the key", function()
	const scene = LoadRig.scene(3)
	const scheduler = scene.world.scheduler
	const caller = LoadRig.start(scene)
	scheduler:cancel(caller)
	const started = scheduler.now
	const _, second = LoadRig.start(scene)
	Spec.equal(second.result, nil, 'not "open": it waits for the first load to be undone')
	scheduler:run(started + 5)
	assert(second.result and second.result.ok, "the second loaded")
	Spec.equal(second.result.profile.loadCount, 2, "after the session the cancelled load opened, and released")
	Spec.equal(#scene.world.backend:versions("Profiles/global", "u_1"), 1)
	Spec.equal(scene.errors, {})
	-- The wait is the load's own: it gives up on `cancel`, and counts against `loadTimeout`.
	const stuck = LoadRig.scene(4, function(world: World.World)
		LoadRig.owner(world)
		world.faults:add({ op = "UpdateAsync", hang = true })
	end, { config = { loadTimeout = 30 } })
	stuck.world.scheduler:cancel((LoadRig.start(stuck)))
	const player = { left = false }
	const _, gaveUp = LoadRig.start(stuck, {
		cancel = function(): boolean
			return player.left
		end,
	})
	const _, timedOut = LoadRig.start(stuck)
	const from = stuck.world.scheduler.now
	stuck.world.scheduler:run(from + 2)
	Spec.equal({ gaveUp.result, timedOut.result }, {}, "both wait")
	player.left = true
	stuck.world.scheduler:run(from + 3)
	Spec.equal(gaveUp.result, { ok = false, reason = "cancelled" })
	Spec.equal(timedOut.result, nil)
	stuck.world.scheduler:run(from + 31)
	Spec.equal(timedOut.result, { ok = false, reason = "timeout" })
end)

Spec.test("Cancelled load: a load that throws tells its caller, or the store, and unmarks its key", function()
	-- A compressed profile, loaded on a server that cannot decompress: the one step of a load that throws.
	const function build(): Scene
		const scene = LoadRig.scene(8, function(world: World.World)
			const packer = LoadRig.store(world, "B", {
				template = { coins = 0, text = string.rep("a", 500) },
				compress = { above = 100 },
			})
			Sim.run(world.scheduler, "B", function()
				const result = packer:load("u_1")
				assert(result.ok, "B loaded")
				result.profile.Data.coins = 5
				result.profile:release()
			end, 10)
			assert(typeof(LoadRig.stored(world).Data.z) == "buffer", "stored compressed")
		end)
		return scene
	end
	const THROWN = "KeepBlox: this profile is compressed, and this server cannot decompress"
	const function plain(scene: Scene): Scene
		const services = table.clone(scene.server.services)
		services.codec = nil
		const store = KeepBlox.store("Profiles", { template = LoadRig.TEMPLATE, services = services })
		const errors: { string } = {}
		store.onError:connect(function(key: string, message: string)
			table.insert(errors, `{key}: {message}`)
		end)
		return { world = scene.world, server = scene.server, store = store, errors = errors }
	end
	-- Its caller there to hear it.
	const heard = plain(build())
	local caught: any = nil
	local again: any = nil
	Sim.run(heard.world.scheduler, "A", function()
		const ok, problem = pcall(heard.store.load, heard.store, "u_1", nil)
		caught = if ok then "nothing thrown" else problem
		const _, second = pcall(heard.store.load, heard.store, "u_1", nil)
		again = second
	end, heard.world.scheduler.now + 300)
	Spec.equal(string.find(caught, THROWN, 1, true) ~= nil, true, `threw {caught}`)
	Spec.equal(heard.errors, {}, "a caller that heard the error is the only one told")
	-- The key is not left marked as opening: the next load of it tries again, and is not told "open".
	Spec.equal(string.find(tostring(again), THROWN, 1, true) ~= nil, true, `the second load got {again}`)
	-- Its caller cancelled meanwhile.
	const orphaned = plain(build())
	const caller, answer = LoadRig.start(orphaned)
	orphaned.world.scheduler:cancel(caller)
	orphaned.world.scheduler:run(orphaned.world.scheduler.now + 5)
	Spec.equal(answer.result, nil)
	Spec.equal(#orphaned.errors, 1)
	Spec.equal(
		string.find(orphaned.errors[1], "u_1: a load failed after its caller was cancelled: ", 1, true),
		1,
		`reported {orphaned.errors[1]}`
	)
	Spec.equal(string.find(orphaned.errors[1], THROWN, 1, true) ~= nil, true)
	Spec.equal(#orphaned.world.scheduler.failures, 0)
	const _, after = LoadRig.start(orphaned)
	orphaned.world.scheduler:run(orphaned.world.scheduler.now + 5)
	Spec.equal(#orphaned.errors, 1, "the second load's caller heard its own error")
	Spec.equal(after.result, nil, 'it threw, as the first did: it was not answered "open"')
end)

Spec.test("Cancelled load: a release, a hand-over and a shutdown reach the session a cancelled load opens", function()
	-- The session a cancelled load opens is listed while it is released, so nothing passes it by. A
	-- store that fails the release's write shows it: the key stays held, and the shutdown waits.
	const scene = LoadRig.scene(3)
	const scheduler = scene.world.scheduler
	-- The claim lands; every write after it fails until the store is back.
	scene.world.backend:observe(function()
		scene.world.faults:add({ op = "UpdateAsync", key = "u_1", error = "503: down" })
	end)
	const caller = LoadRig.start(scene)
	scheduler:cancel(caller)
	scheduler:run(scheduler.now + 10)
	Spec.equal(LoadRig.heldBy(scene.world, scene.server), true, "the release cannot land yet")
	Spec.equal(#scene.errors >= 3, true, "and its tries are reported")
	Spec.equal(scene.errors[1], "u_1: save failed: 503: down")
	const _, waiting = LoadRig.start(scene)
	scheduler:run(scheduler.now + 10)
	Spec.equal(waiting.result, nil, "a load of the key waits for it")
	scene.world.faults:clear()
	Sim.run(scheduler, "A", function()
		const started = scheduler.now
		scene.server.closing[1]()
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "the key was free when the close returned")
		Spec.equal(scheduler.now - started < 6, true, "within one backoff")
	end, scheduler.now + 60)
	Spec.equal(waiting.result, { ok = false, reason = "closing" })
	Spec.equal(#scheduler.failures, 0)
end)

return nil
