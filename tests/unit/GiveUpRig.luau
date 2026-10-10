--!strict
--- The rig of the specs on a load that gives up (tests/unit/LoadGivesUp.luau): the sweep that makes
--- the load's `cancel` turn true, or closes its store, at every point the world can stand at while
--- the load runs, and then has another server load the key.
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const Sim = require("./Sim")
const Spec = require("../Spec")

const GiveUpRig = {}

--> Seconds within which a server gets a free key: its own first beat, then one request.
GiveUpRig.FREE = 1

--> How the load is made to give up: its player leaves (`cancel` answers true from then on), or its
--> server shuts down.
export type Way = "left" | "close"

export type Swept = {
	--> How many points the load was made to give up at.
	points: number,
	--> At how many of them the store already showed the key as held by A.
	held: number,
	--> How the loads answered, by reason ("ok" for a profile).
	answers: { [string]: number },
	--> The longest another server then took to get the key, in seconds; and the longest when A had
	--> taken the key before it gave up, so that it was A's to free.
	slowest: number,
	slowestFreed: number,
	--> The answer of the load nobody stopped.
	result: any,
}

-- Whether A holds "u_1" in the store, and whether it has a session that will release it.
const function holds(scene: LoadRig.Scene): (boolean, boolean)
	return LoadRig.heldBy(scene.world, scene.server), scene.store:profiles()["u_1"] ~= nil
end

--> Another server, `name`, loads "u_1": it gets the key within `within` seconds, reads exactly `coins`,
--> and releases it. Returns the seconds the load took.
function GiveUpRig.next(scene: LoadRig.Scene, name: string, coins: number, within: number, label: string): number
	const world = scene.world
	const scheduler = world.scheduler
	const store, server = LoadRig.store(world, name, scene.options)
	local took = -1
	Sim.run(scheduler, name, function()
		const started = scheduler.now
		const result = store:load("u_1")
		took = scheduler.now - started
		assert(result.ok, `{label}: {name} did not get the key ({(result :: any).reason}) in {took} s`)
		Spec.equal(result.profile.Data.coins, coins, `{label}: the coins {name} read`)
		Spec.equal(LoadRig.heldBy(world, server), true, `{label}: held by {name}`)
		result.profile:release()
		Spec.equal(result.profile.LastSavedData.coins, coins, `{label}: the coins {name} stored`)
		Spec.equal(LoadRig.stored(world).MetaData.ActiveSession, nil, `{label}: free after {name}`)
	end, scheduler.now + 300)
	Spec.equal(took >= 0 and took <= within, true, `{label}: {name} got the key in {took} s, not within {within}`)
	return took
end

--> Makes A's load of "u_1" give up after 0, 1, 2, ... steps of the world, each in a fresh scene, until
--> a load answers first. Each time:
--> - the load answers, and from that moment A holds the key only with a session that releases it;
--> - a player who left gets "cancelled", or the profile (the load was past its last look), which is
-->   released as a game releases it; a closing server answers "closing", or the profile already
-->   ended by the shutdown, and the key is free when the close returns;
--> - another server then gets the key within `within` seconds and reads exactly `coins`.
--> No scene may report an error.
function GiveUpRig.sweep(build: () -> LoadRig.Scene, way: Way, coins: number, within: number): Swept
	const swept: Swept = { points = 0, held = 0, answers = {}, slowest = 0, slowestFreed = 0, result = nil }
	while true do
		const scene = build()
		const world = scene.world
		const scheduler = world.scheduler
		const player = { left = false }
		const _, answer = LoadRig.start(scene, {
			cancel = function(): boolean
				return player.left
			end,
		})
		for _ = 1, swept.points do
			scheduler:step()
		end
		if answer.result ~= nil then
			swept.result = answer.result
			return swept
		end
		assert(swept.points < 2000, "the load never answered")
		const label = `{way} after {swept.points} steps`
		const held = LoadRig.heldBy(world, scene.server)
		if held then
			swept.held += 1
		end
		if way == "left" then
			player.left = true
			local guard = 0
			while answer.result == nil do
				assert(scheduler:step() and guard < 100_000, `{label}: the load never answered`)
				guard += 1
			end
		else
			Sim.run(scheduler, "A", function()
				const started = scheduler.now
				scene.server.closing[1]()
				Spec.equal(scheduler.now - started < 25, true, `{label}: the close did not run out its deadline`)
				Spec.equal(answer.result ~= nil, true, `{label}: the close waited for the load's answer`)
				Spec.equal({ holds(scene) }, { false, false }, `{label}: the key was free when the close returned`)
			end, scheduler.now + 60)
		end
		const result = answer.result
		const reason: string = if result.ok then "ok" else result.reason
		swept.answers[reason] = (swept.answers[reason] or 0) + 1
		if result.ok then
			const profile: KeepBlox.Profile<any> = result.profile
			Spec.equal(profile.Data.coins, coins, `{label}: the coins of the profile the load answered with`)
			if way == "left" then
				-- The load was past its last look at `cancel`: the game holds the profile, finds its
				-- player gone and releases it.
				Spec.equal({ holds(scene) }, { true, true }, `{label}: A holds the key with a session`)
				Spec.equal(profile:isActive(), true, `{label}: active`)
				Sim.run(scheduler, "A", function()
					profile:release()
				end, scheduler.now + 30)
			end
			Spec.equal(profile:isActive(), false, `{label}: ended`)
			Spec.equal(profile.LastSavedData.coins, coins, `{label}: the coins its release stored`)
		else
			Spec.equal(result, { ok = false, reason = if way == "left" then "cancelled" else "closing" }, label)
		end
		-- Checked in the store itself, the moment the load has answered.
		Spec.equal({ holds(scene) }, { false, false }, `{label}: A holds the key, or a session, after its answer`)
		-- A key A had taken is A's to free: the next server gets it at its first request, not after
		-- finding A's beat still (a closed server) or never (a live one).
		const freed = held or result.ok
		const took = GiveUpRig.next(scene, "C", coins, if freed then GiveUpRig.FREE else within, label)
		swept.slowest = math.max(swept.slowest, took)
		if freed then
			swept.slowestFreed = math.max(swept.slowestFreed, took)
		end
		Spec.equal(scene.errors, {}, `{label}: nothing was reported`)
		Spec.equal(#scheduler.failures, 0, `{label}: no thread failed`)
		swept.points += 1
	end
end

return GiveUpRig
