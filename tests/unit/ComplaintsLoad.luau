--!strict
--- Complaints about load times, leaks and size, each as a spec against KeepBlox (see Complaints.luau).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

const function setup(players: number): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(11)
	const server = world:server({ name = "A", players = players })
	const store = KeepBlox.store("Profiles", { template = TEMPLATE, services = server.services })
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	return world, server, store, errors
end

Spec.test("Complaints: 300 joins and leaves leave nothing behind (DataStore2#124, ProfileService p40 #851)", function()
	const world, _, store, errors = setup(1)
	local slowest = 0
	Sim.run(world.scheduler, "A", function()
		for index = 1, 300 do
			const started = world.scheduler.now
			const result = store:load(`u_{index % 7}`)
			assert(result.ok, `load {index}`)
			slowest = math.max(slowest, world.scheduler.now - started)
			result.profile.Data.coins = index
			result.profile:release()
		end
	end, 3600)
	Spec.equal(next(store:profiles()), nil, "no profile is left open")
	Spec.equal(world.bus:connected("A"), 0, "no subscription is left connected")
	-- The renewal loop and the MemoryStore heartbeat are the two threads a store keeps.
	Spec.equal(world.scheduler:count("A"), 2, "no thread is left behind")
	Spec.truthy(slowest < 2, `the last loads are as fast as the first (slowest {slowest} s)`)
	Spec.equal(errors, {})
end)

Spec.test("Complaints: 50 players joining at once all load quickly (ProfileStore p10 #207)", function()
	const world, _, store, errors = setup(50)
	local loaded = 0
	local slowest = 0
	Sim.run(world.scheduler, "A", function()
		for index = 1, 50 do
			world.scheduler:spawn(function()
				const started = world.scheduler.now
				const result = store:load(`u_{index}`)
				if result.ok then
					loaded += 1
				end
				slowest = math.max(slowest, world.scheduler.now - started)
			end, "A")
		end
	end, 60)
	Spec.equal(loaded, 50)
	Spec.truthy(slowest < 2, `slowest load {slowest} s`)
	Spec.equal(errors, {})
end)

Spec.test("Complaints: reading versions does not hold up loads (ProfileService p60 #1270)", function()
	const world, _, store = setup(10)
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_0")
		assert(result.ok, "loaded")
		result.profile:release()
	end, 30)
	world.faults.latency = { min = 1, max = 1 }
	local took = math.huge
	Sim.run(world.scheduler, "A", function()
		for _ = 1, 5 do
			world.scheduler:spawn(function()
				for _ = 1, 5 do
					const versions = store:versions("u_0")
					store:readVersion("u_0", versions[1].version)
				end
			end, "A")
		end
		const started = world.scheduler.now
		assert((store:load("u_1") :: any).ok, "loaded while support reads run")
		took = world.scheduler.now - started
	end, world.scheduler.now + 120)
	Spec.truthy(took <= 1.5, `the load took {took} s`)
end)

Spec.test(
	"Complaints: a profile over the size limit is refused with its path; the last save stays (ProfileService p40 #848)",
	function()
		const world, _, store, errors = setup(1)
		Sim.run(world.scheduler, "A", function()
			const result = store:load("u_1")
			assert(result.ok, "loaded")
			const profile = result.profile
			profile.Data.coins = 3
			profile:save()
			profile.Data.blob = string.rep("x", 4_200_000)
			Spec.equal(profile:save(), true, "the lease still renews")
			profile.Data.blob = nil
			profile.Data.coins = 4
			profile:release()
		end, 120)
		Spec.equal(#errors, 1)
		Spec.truthy(string.find(errors[1], "(most of it: Data.blob, 4200002 bytes)", 1, true) ~= nil, errors[1])
		Spec.equal((world.backend:latest("Profiles/global", "u_1") :: any).value.Data, { coins = 4 })
	end
)

return nil
