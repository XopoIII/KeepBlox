--!strict
--- A load that throws past its claim keeps nothing: the key is given back before the error goes on,
--- with a dead owner's last beat stored first, so no live server is left holding a key it has no
--- session for (src/Open.luau, src/LetGo.luau, src/Claim.luau, src/Recover.luau; issue 34).
---
--- The sweep throws once from a seam the load's own thread calls (its clock, the request budget, the
--- memory store), at every such call between the claim landing and the session being listed.
const GiveUpRig = require("./GiveUpRig")
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const LoadScenes = require("./LoadScenes")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene
type Trip = {
	--> Which call of the load's thread throws, counted from its claim landing.
	at: number,
	count: number,
	armed: boolean,
	--> The seam that threw, once one has.
	fired: string?,
	--> The thread the load runs in: the one that asks for the load's GUID.
	thread: thread?,
	--> Writes of "u_1" by A.
	writes: number,
	--> Whether A has listed a session: the load is over then.
	listed: () -> boolean,
}

-- A's services, whose seams throw once at the call `trip.at`.
const function tripping(trip: Trip): LoadRig.Dress
	return function(server: World.Server): any
		const function guard(name: string, fn: (...any) -> ...any): (...any) -> ...any
			return function(...: any): ...any
				if trip.armed and trip.fired == nil and coroutine.running() == trip.thread and not trip.listed() then
					trip.count += 1
					if trip.count == trip.at then
						trip.fired = name
						error(`tripped in {name}`, 0)
					end
				end
				return fn(...)
			end
		end
		const services: any = table.clone(server.services)
		const clock: any = table.clone(services.clock)
		for _, name in { "now", "time", "wait", "spawn" } do
			clock[name] = guard(`clock.{name}`, clock[name])
		end
		services.clock = clock
		const dataStores: any = table.clone(services.dataStores)
		dataStores.GetRequestBudgetForRequestType =
			guard("the request budget", dataStores.GetRequestBudgetForRequestType)
		services.dataStores = dataStores
		const memory: any = table.clone(services.memory)
		memory.GetSortedMap = guard("the memory store", memory.GetSortedMap)
		services.memory = memory
		const guid = services.guid
		services.guid = function(): string
			trip.thread = coroutine.running()
			return guid()
		end
		return services
	end
end

-- The scene of `case` with A's seams tripping; the trip is armed from the write that makes the key
-- A's until A lists a session.
const function tripped(case: LoadScenes.Case, at: number): (Scene, Trip)
	local scene: Scene
	const trip: Trip = {
		at = at,
		count = 0,
		armed = false,
		fired = nil,
		thread = nil,
		writes = 0,
		listed = function(): boolean
			return scene.store:profiles()["u_1"] ~= nil
		end,
	}
	scene = case.build(tripping(trip))
	scene.world.backend:observe(function(event: any)
		if event.key ~= "u_1" or event.writer ~= "A" then
			return
		end
		trip.writes += 1
		const session = event.version.value.MetaData.ActiveSession
		trip.armed = session ~= nil and session[2] == scene.server.services.jobId
	end)
	return scene, trip
end

for _, case in LoadScenes do
	Spec.test(`Load throws: {case.name}, a throw at every call past the claim leaves the key free and whole`, function()
		local at = 1
		const writes: { number } = {}
		const seams: { [string]: boolean } = {}
		while true do
			const scene, trip = tripped(case, at)
			const scheduler = scene.world.scheduler
			const label = `the call {at}`
			local outcome: any = nil
			Sim.run(scheduler, "A", function()
				outcome = table.pack(pcall(scene.store.load, scene.store, "u_1", nil))
				-- Checked in the store itself, the moment the load has thrown.
				if trip.fired then
					Spec.equal(
						LoadRig.heldBy(scene.world, scene.server),
						false,
						`{label}: A holds the key after the throw`
					)
				end
			end, scheduler.now + 60)
			assert(outcome, `{label}: the load neither answered nor threw`)
			if trip.fired == nil then
				-- Past the last call: the load nobody tripped, which the others are measured against.
				assert(outcome[1] and outcome[2].ok, `{label}: the load nobody tripped`)
				Spec.equal(outcome[2].profile.Data.coins, case.coins)
				Spec.equal(at > 3, true, `only {at - 1} calls could throw`)
				local twice = 0
				for index = 1, at - 1 do
					-- The same writes as the load nobody tripped, and one more: the key given back. A
					-- dead owner's last beat is stored once, whether the throw came before or after; only
					-- a throw while that very write is on its way sends it again, saying the same.
					const more = writes[index] - trip.writes
					twice += if more == 2 then 1 else 0
					Spec.equal(more == 1 or more == 2, true, `the call {index}: {more} more writes of the key by A`)
				end
				Spec.equal(twice, if case.lastBeat then 1 else 0, "throws that sent a write again")
				Spec.equal(seams["clock.now"], true, "the clock was among the seams that threw")
				return
			end
			Spec.equal({ outcome[1], outcome[2] }, { false, `tripped in {trip.fired}` } :: { any }, label)
			seams[trip.fired :: string] = true
			writes[at] = trip.writes
			Spec.equal(next(scene.store:profiles()), nil, `{label}: no profile is open`)
			Spec.equal(scene.errors, {}, `{label}: the caller heard the error, the store did not`)
			-- Free at once for the next server, with everything the dead owner had played.
			GiveUpRig.next(scene, "C", case.coins, GiveUpRig.FREE, label)
			Spec.equal(#scheduler.failures, 0, `{label}: no thread failed`)
			at += 1
		end
	end)
end

-- Whether the store has shown "u_1" as A's since this was called: A's claim has landed.
const function landing(scene: Scene): () -> boolean
	local landed = false
	scene.world.backend:observe(function(event: any)
		const session = event.version.value.MetaData.ActiveSession
		landed = landed or (session ~= nil and session[2] == scene.server.services.jobId)
	end)
	return function(): boolean
		return landed
	end
end

const THROWN = "KeepBlox: this profile is compressed, and this server cannot decompress"

-- Whether `text` is `head`, then the place the error was thrown at, then `THROWN`.
const function thrownAfter(text: any, head: string): boolean
	return type(text) == "string"
		and string.sub(text, 1, #head) == head
		and string.sub(text, -#THROWN) == THROWN
		and string.match(string.sub(text, #head + 1, -#THROWN - 1), "^[%w_/%.%-]*src/%a+:%d+: $") ~= nil
end

-- Server B stores "u_1" compressed, with `size` bytes of text and 5 coins; with `crash`, it then plays
-- a sixth coin, which only its beats hold, and dies. A's store there cannot decompress.
const function compressed(seed: number, size: number, crash: boolean): Scene
	const options = { template = { coins = 0, text = string.rep("a", size) }, compress = { above = 100 } }
	const scene = LoadRig.scene(seed, function(world: World.World)
		const packer, server = LoadRig.store(world, "B", options)
		Sim.run(world.scheduler, "B", function()
			const result = packer:load("u_1")
			assert(result.ok, "B loaded")
			result.profile.Data.coins = 5
			if crash then
				assert(result.profile:save(), "B saved")
				result.profile.Data.coins = 6
			else
				result.profile:release()
			end
		end, 20)
		assert(typeof(LoadRig.stored(world).Data.z) == "buffer", "stored compressed")
		if crash then
			server:crash()
		end
	end, { template = options.template }, function(server: World.Server): any
		const services = table.clone(server.services)
		services.codec = nil
		return services
	end)
	-- Another server takes the store as B had it.
	scene.options = options
	return scene
end

Spec.test("Load throws: a profile this server cannot decompress is given back, not left held", function()
	const scene = compressed(8, 500, false)
	const scheduler = scene.world.scheduler
	const spent = scene.server.budget.spent
	local caught: any = nil
	Sim.run(scheduler, "A", function()
		const ok, problem = pcall(scene.store.load, scene.store, "u_1", nil)
		caught = if ok then "nothing thrown" else problem
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "A holds the key after the throw")
	end, scheduler.now + 30)
	Spec.equal(thrownAfter(caught, ""), true, `threw {caught}`)
	Spec.equal(scene.errors, {})
	-- The claim and the give-back: two requests, each a read and a write.
	Spec.equal({ spent.StandardRead, spent.StandardWrite }, { 2, 2 })
	Spec.equal(LoadRig.stored(scene.world).MetaData.ActiveSession, nil)
	Spec.equal(typeof(LoadRig.stored(scene.world).Data.z), "buffer", "the data is as it was stored")
	-- A server that can decompress has it at its first request, though A lives on.
	GiveUpRig.next(scene, "C", 5, GiveUpRig.FREE, "after the throw")
	Spec.equal(#scheduler.failures, 0)
end)

Spec.test("Load throws: a dead owner's whole last beat needs none of the data this server cannot read", function()
	const scene = compressed(9, 500, true)
	const scheduler = scene.world.scheduler
	local loaded: any = nil
	Sim.run(scheduler, "A", function()
		loaded = scene.store:load("u_1")
	end, scheduler.now + 60)
	assert(loaded and loaded.ok, `A did not load ({loaded and loaded.reason})`)
	Spec.equal(loaded.profile.Data, { coins = 6, text = string.rep("a", 500) })
	Spec.equal(
		LoadRig.stored(scene.world).Data,
		{ coins = 6, text = string.rep("a", 500) },
		"stored as the beat held it"
	)
	Spec.equal(scene.errors, {})
	Sim.run(scheduler, "A", function()
		loaded.profile:release()
	end, scheduler.now + 30)
	GiveUpRig.next(scene, "C", 6, GiveUpRig.FREE, "after A")
end)

Spec.test("Load throws: a last beat of edits this server cannot apply is reported, and the key given back", function()
	-- Known, not fixed (issue 36): the edits were made against data only a server that decompresses
	-- can read, and a key given back has no previous owner to recover from, so that beat is lost.
	const function build(): Scene
		return compressed(10, 3000, true)
	end
	const REPORT = "u_1: the previous owner's last beat could not be stored: "
	-- The load throws.
	const thrown = build()
	local caught: any = nil
	Sim.run(thrown.world.scheduler, "A", function()
		const ok, problem = pcall(thrown.store.load, thrown.store, "u_1", nil)
		caught = if ok then "nothing thrown" else problem
		Spec.equal(LoadRig.heldBy(thrown.world, thrown.server), false, "A holds the key after the throw")
	end, thrown.world.scheduler.now + 60)
	Spec.equal(thrownAfter(caught, ""), true, `threw {caught}`)
	Spec.equal({ #thrown.errors, thrownAfter(thrown.errors[1], REPORT) }, { 1, true } :: { any }, thrown.errors[1])
	GiveUpRig.next(thrown, "C", 5, GiveUpRig.FREE, "after the throw")
	-- The load gives up as its claim lands: it answers, and does not throw.
	const left = build()
	const options: KeepBlox.LoadOptions = { cancel = landing(left) }
	local answer: any = nil
	Sim.run(left.world.scheduler, "A", function()
		answer = left.store:load("u_1", options)
		Spec.equal(LoadRig.heldBy(left.world, left.server), false, "A holds the key after its answer")
	end, left.world.scheduler.now + 60)
	Spec.equal(answer, { ok = false, reason = "cancelled" })
	Spec.equal({ #left.errors, thrownAfter(left.errors[1], REPORT) }, { 1, true } :: { any }, left.errors[1])
	GiveUpRig.next(left, "C", 5, GiveUpRig.FREE, "after the answer")
end)

Spec.test("Load throws: a `cancel` that throws as the claim lands leaves the key free and whole", function()
	const scene = LoadScenes[3].build()
	Spec.equal(LoadScenes[3].lastBeat, true)
	const scheduler = scene.world.scheduler
	const landed = landing(scene)
	const options: KeepBlox.LoadOptions = {
		cancel = function(): boolean
			if landed() then
				error("the game's cancel threw", 0)
			end
			return false
		end,
	}
	local caught: any = nil
	Sim.run(scheduler, "A", function()
		const ok, problem = pcall(scene.store.load, scene.store, "u_1", options)
		caught = if ok then "nothing thrown" else problem
		Spec.equal(LoadRig.heldBy(scene.world, scene.server), false, "A holds the key after the throw")
	end, scheduler.now + 60)
	Spec.equal(caught, "the game's cancel threw")
	Spec.equal(scene.errors, {})
	GiveUpRig.next(scene, "C", 6, GiveUpRig.FREE, "after the throw")
	Spec.equal(#scheduler.failures, 0)
end)

return nil
