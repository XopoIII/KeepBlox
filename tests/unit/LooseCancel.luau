--!strict
--- The game's code that throws inside a load (issue 37): a `cancel` that throws ends the load as one
--- that answers true does, wherever the load stood, and then reaches the caller; and a load nobody
--- holds is released even when its release throws (src/Open.luau).
const CancelRig = require("./CancelRig")
const GiveUpRig = require("./GiveUpRig")
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Sim = require("./Sim")
const Spec = require("../Spec")

type Scene = LoadRig.Scene

-- A's load of "u_1" whose `cancel` throws from `points` steps of the world on. Returns what the load
-- did (`pcall`'s results), or nil when it had answered before.
const function thrownAt(scene: Scene, points: number): { any }?
	const scheduler = scene.world.scheduler
	const game = { throws = false, asked = 0 }
	local outcome: { any }? = nil
	scheduler:resume(function()
		outcome = table.pack(pcall(
			scene.store.load,
			scene.store,
			"u_1",
			{
				cancel = function(): boolean
					game.asked += 1
					if game.throws then
						error("the game's cancel threw", 0)
					end
					return false
				end,
			} :: KeepBlox.LoadOptions
		))
	end, "A")
	for _ = 1, points do
		scheduler:step()
	end
	if outcome ~= nil then
		return nil
	end
	game.throws = true
	local guard = 0
	while outcome == nil do
		assert(scheduler:step() and guard < 100_000, `cancel threw after {points} steps: the load never ended`)
		guard += 1
	end
	const asked = game.asked
	Sim.run(scheduler, "A", function()
		scheduler:wait(10)
	end, scheduler.now + 20)
	Spec.equal(game.asked, asked, `after {points} steps: a load that ended asks its cancel no more`)
	return outcome
end

for _, case in LoadScenes do
	Spec.test(`Loose cancel: {case.name}, a cancel that throws at any point ends the load whole`, function()
		local points = 0
		local throws = 0
		while true do
			const scene = case.build()
			const world = scene.world
			const label = `cancel threw after {points} steps`
			const outcome = thrownAt(scene, points)
			if outcome == nil then
				break
			end
			assert(points < 2000, "the load never answered")
			if outcome[1] then
				-- The load was past its last look at `cancel`: the game has the profile.
				Spec.equal(outcome[2].ok, true, label)
				Sim.run(world.scheduler, "A", function()
					outcome[2].profile:release()
				end, world.scheduler.now + 30)
			else
				throws += 1
				Spec.equal(outcome[2], "the game's cancel threw", label)
			end
			Spec.equal(LoadRig.heldBy(world, scene.server), false, `{label}: A holds the key`)
			Spec.equal(next(scene.store:profiles()), nil, `{label}: a profile is open`)
			-- The load's hand-over listener is gone with it (before 0.6.10 it stayed subscribed).
			Spec.equal(world.bus:connected("A"), 0, `{label}: subscriptions left`)
			Spec.equal(scene.errors, {}, `{label}: the caller heard the error, the store did not`)
			GiveUpRig.next(scene, "C", case.coins, case.within, label)
			Spec.equal(#world.scheduler.failures, 0, `{label}: no thread failed`)
			points += 1
		end
		Spec.equal(throws > 0, true, `{points} points, none of which threw`)
	end)
end

Spec.test("Loose cancel: a load nobody holds is released though its release throws, at a later try", function()
	-- A compressing store whose codec breaks: the release of the session a cancelled load opened
	-- throws. The template has grown since the data was stored, so that release has data to pack.
	const rig = CancelRig.new({ template = { coins = 0, text = string.rep("a", 500) }, compress = { above = 100 } })
	const world = rig.world
	const scheduler = world.scheduler
	const before =
		KeepBlox.store("Profiles", { template = { coins = 0 }, services = world:server({ name = "B" }).services })
	Sim.run(scheduler, "B", function()
		const first = before:load("u_1")
		assert(first.ok, "B loaded")
		first.profile:release()
	end, 20)
	rig.codec.broken = true
	local caller: thread? = nil
	scheduler:resume(function()
		caller = coroutine.running()
		rig.store:load("u_1")
	end, "A")
	scheduler:cancel(caller :: thread)
	Sim.run(scheduler, "A", function()
		-- Tried at once, then 1, 3, 7, 12 and 17 seconds later (from `backoffMin`, doubling up to
		-- `backoffMax`): six tries in 18 s.
		scheduler:wait(18)
	end, scheduler.now + 19)
	const REPORT = "u_1: the release of a load nobody holds failed, and is tried again: the codec is down"
	Spec.equal(rig.errors, { REPORT, REPORT, REPORT, REPORT, REPORT, REPORT })
	Spec.equal(CancelRig.stored(world).MetaData.ActiveSession ~= nil, true, "still held")
	rig.codec.broken = false
	Sim.run(scheduler, "A", function()
		-- The seventh try, 22 seconds after the first.
		scheduler:wait(5)
		Spec.equal(CancelRig.stored(world).MetaData.ActiveSession, nil, "released")
		Spec.equal(next(rig.store:profiles()), nil, "no profile is open")
		-- A later load of the key waits for nothing, and gets it.
		const started = scheduler.now
		const again = rig.store:load("u_1")
		assert(again.ok, "loaded again")
		Spec.equal(scheduler.now - started < 1, true)
		Spec.equal(#again.profile.Data.text, 500)
		again.profile:release()
	end, scheduler.now + 30)
	Spec.equal(#rig.errors, 6, "nothing more was reported")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test(
	"Loose cancel: a cancel that throws while the load waits for this server's release reaches the caller",
	function()
		const scene = LoadRig.scene(3)
		const scheduler = scene.world.scheduler
		Sim.run(scheduler, "A", function()
			const first = scene.store:load("u_1")
			assert(first.ok, "loaded")
			-- The release cannot land for a while: a second load of the key waits for it.
			scene.world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", error = "503: down", times = 3 })
			scheduler:spawn(function()
				first.profile:release()
			end, "A")
			scheduler:wait(0.5)
			const ok, problem = pcall(
				scene.store.load,
				scene.store,
				"u_1",
				{
					cancel = function(): boolean
						error("the game's cancel threw", 0)
					end,
				} :: KeepBlox.LoadOptions
			)
			Spec.equal({ ok, problem }, { false, "the game's cancel threw" } :: { any })
			scheduler:wait(10)
			Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "the release landed all the same")
		end, scheduler.now + 60)
		-- A cancel that throws nothing at all is still an error the caller hears.
		const bare = LoadScenes[2].build()
		Sim.run(bare.world.scheduler, "A", function()
			const ok, problem = pcall(
				bare.store.load,
				bare.store,
				"u_1",
				{
					cancel = function(): boolean
						error(nil)
					end,
				} :: KeepBlox.LoadOptions
			)
			Spec.equal({ ok, problem }, { false, "KeepBlox: `cancel` threw nil" } :: { any })
		end, bare.world.scheduler.now + 60)
		Spec.equal(bare.world.bus:connected("A"), 0)
	end
)

return nil
