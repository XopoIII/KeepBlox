--!strict
--- The rig of the specs on a cancelled `store:load` (tests/unit/CancelledLoad.luau): a world in which
--- "u_1" is in some state before server A loads it, and the sweep that cancels the load's caller at
--- every point the world can stand at while the load runs.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const LoadRig = {}

LoadRig.TEMPLATE = { coins = 0 } :: { [any]: any }

export type Scene = {
	world: World.World,
	server: World.Server,
	store: KeepBlox.Store<any>,
	errors: { string },
}

--> What to do right after the caller was cancelled:
--> - "again": load the key again at once;
--> - "alone": leave the server alone for half a minute first;
--> - "close": shut the server down at once.
export type After = "again" | "alone" | "close"

--> A store of `name` on a new server of `world`, with `options` added to its own.
function LoadRig.store(
	world: World.World,
	name: string,
	options: { [string]: any }?
): (KeepBlox.Store<any>, World.Server)
	const server = world:server({ name = name, players = 1 })
	const settings: { [string]: any } = { template = LoadRig.TEMPLATE, services = server.services }
	for key, value in options or {} do
		settings[key] = value
	end
	return KeepBlox.store("Profiles", settings :: any), server
end

--> A world of `seed`, with `before` run in it first, then server "A" and its store.
function LoadRig.scene(seed: number, before: ((world: World.World) -> ())?, options: { [string]: any }?): Scene
	const world = World.new(seed)
	if before then
		before(world)
	end
	const store, server = LoadRig.store(world, "A", options)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	return { world = world, server = server, store = store, errors = errors }
end

--> Server B holds "u_1" with 5 coins stored and a sixth only in its beats; returns B.
function LoadRig.owner(world: World.World): World.Server
	const store, server = LoadRig.store(world, "B")
	Sim.run(world.scheduler, "B", function()
		const result = store:load("u_1")
		assert(result.ok, "B loaded")
		result.profile.Data.coins = 5
		assert(result.profile:save(), "B saved")
		result.profile.Data.coins = 6
	end, 20)
	return server
end

--> The record of "u_1" as the store holds it now, or nil when it was never written.
function LoadRig.stored(world: World.World): any
	const latest = world.backend:latest("Profiles/global", "u_1")
	return if latest then latest.value else nil
end

--> Whether "u_1" is held by a session of `server` in the store.
function LoadRig.heldBy(world: World.World, server: World.Server): boolean
	const record = LoadRig.stored(world)
	const session = record and record.MetaData.ActiveSession
	return session ~= nil and session[2] == server.services.jobId
end

--> Starts `store:load("u_1")` in a thread of A, which runs at once up to its first yield. Returns the
--> thread and the table its answer lands in.
function LoadRig.start(scene: Scene, options: KeepBlox.LoadOptions?): (thread, { result: any })
	const answer = { result = nil :: any }
	local thread: thread? = nil
	scene.world.scheduler:resume(function()
		thread = coroutine.running()
		answer.result = scene.store:load("u_1", options)
	end, "A")
	return thread :: thread, answer
end

-- A load of "u_1" on A gets a session holding `coins`, plays on it and releases it: the key works.
const function works(scene: Scene, coins: number, label: string)
	const world = scene.world
	const result = scene.store:load("u_1")
	assert(result.ok, `{label}: loaded again ({(result :: any).reason})`)
	const profile = result.profile
	Spec.equal(profile.Data.coins, coins, `{label}: the coins`)
	Spec.equal(profile:isActive(), true, `{label}: active`)
	Spec.equal(LoadRig.heldBy(world, scene.server), true, `{label}: held by A`)
	profile.Data.coins = coins + 1
	profile:release()
	Spec.equal(LoadRig.stored(world).Data.coins, coins + 1, `{label}: the release stored the play`)
	Spec.equal(LoadRig.stored(world).MetaData.ActiveSession, nil, `{label}: the key is free`)
	Spec.equal(next(scene.store:profiles()), nil, `{label}: no profile is open`)
end

export type Swept = {
	--> How many points the caller was cancelled at.
	cancels: number,
	--> At how many of them the store already showed the key as held by A.
	held: number,
	--> The answer of the load nobody cancelled.
	result: any,
}

--> Cancels the caller of A's load of "u_1" after 0, 1, 2, ... steps of the world, each in a fresh
--> scene, until a load answers before its cancel. After each cancel does `after`, then checks that
--> nothing is left half done: A does not hold the key without a session, and a load of it works and
--> gets `coins`. No scene may report an error.
function LoadRig.sweep(build: () -> Scene, after: After, coins: number): Swept
	local steps = 0
	local held = 0
	while true do
		const scene = build()
		const world = scene.world
		const scheduler = world.scheduler
		const caller, answer = LoadRig.start(scene)
		for _ = 1, steps do
			scheduler:step()
		end
		if answer.result ~= nil then
			return { cancels = steps, held = held, result = answer.result }
		end
		assert(steps < 2000, "the load never answered")
		const label = `cancelled after {steps} steps, then {after}`
		if LoadRig.heldBy(world, scene.server) then
			held += 1
		end
		scheduler:cancel(caller)
		Sim.run(scheduler, "A", function()
			if after == "alone" then
				scheduler:wait(30)
				Spec.equal(LoadRig.heldBy(world, scene.server), false, `{label}: A let go of the key`)
				Spec.equal(next(scene.store:profiles()), nil, `{label}: no profile is open`)
			elseif after == "close" then
				const started = scheduler.now
				scene.server.closing[1]()
				Spec.equal(
					LoadRig.heldBy(world, scene.server),
					false,
					`{label}: the key was free when the close returned`
				)
				Spec.equal(scheduler.now - started < 25, true, `{label}: the close did not run out its deadline`)
				return
			end
			works(scene, coins, label)
		end, scheduler.now + 400)
		Spec.equal(answer.result, nil, `{label}: the cancelled caller never went on`)
		Spec.equal(scene.errors, {}, `{label}: nothing was reported`)
		Spec.equal(#scheduler.failures, 0, `{label}: no thread failed`)
		steps += 1
	end
end

return LoadRig
