--!strict
--- Rollout stories: ProfileStore and KeepBlox servers side by side on the same keys, as during a
--- migration, and back again for a rollback. Both libraries use the same data store, so the ledger
--- checks every write whichever library made it (.claude/plan/04-compat.md).
const Adapter = require("./Adapter")
const KeepBloxAdapter = require("./KeepBloxAdapter")
const ProfileStoreAdapter = require("./ProfileStoreAdapter")
const Scenarios = require("./Scenarios")
const Simulation = require("./Simulation")

const PS: Adapter.Adapter = ProfileStoreAdapter
const KB: Adapter.Adapter = KeepBloxAdapter.default

const Mixed = {}

--> A ProfileStore server holds the key; the player shows up on a KeepBlox server (and the reverse).
const function handOff(from: Adapter.Adapter, to: Adapter.Adapter): Scenarios.Scenario
	return function(seed: number): Simulation.Report
		const sim = Simulation.new(seed, from)
		const a, b = sim:server("A", nil, from), sim:server("B", nil, to)
		a:join("u_1")
		sim:run(sim.scheduler.random:integer(10, 120))
		b:join("u_1")
		sim:run(10)
		a:leave("u_1")
		sim:run(120)
		b:leave("u_1")
		sim:run(10)
		a:join("u_1")
		sim:run(60)
		a:leave("u_1")
		sim:run(120)
		return sim:finish()
	end
end

Mixed.profileStoreToKeepBlox = handOff(PS, KB)
Mixed.keepBloxToProfileStore = handOff(KB, PS)

--> The owner crashes; the player returns on a server running the other library.
const function crash(from: Adapter.Adapter, to: Adapter.Adapter): Scenarios.Scenario
	return function(seed: number): Simulation.Report
		const sim = Simulation.new(seed, from)
		const a, b = sim:server("A", nil, from), sim:server("B", nil, to)
		a:join("u_1")
		sim:run(sim.scheduler.random:integer(30, 290))
		a:crash()
		b:join("u_1")
		sim:run(900)
		b:leave("u_1")
		sim:run(120)
		return sim:finish()
	end
end

Mixed.profileStoreCrash = crash(PS, KB)
Mixed.keepBloxCrash = crash(KB, PS)

--> A rolling migration: four servers, two on each library, with random play over ten keys,
--> rejoins across libraries and the odd crash, for 20 minutes.
function Mixed.rollout(seed: number): Simulation.Report
	const sim = Simulation.new(seed, PS)
	const random = sim.scheduler.random
	const libraries = { PS, KB, PS, KB }
	const servers = {}
	for index, library in libraries do
		servers[index] = sim:server(`S{index}`, nil, library)
	end
	local next = #servers + 1
	const where: { [string]: any } = {}
	for _ = 1, 120 do
		const key = `u_{random:integer(1, 10)}`
		const roll = random:integer(1, 25)
		if roll == 1 then
			const victim = random:integer(1, #servers)
			servers[victim]:crash()
			for k, server in where do
				if server == servers[victim] then
					where[k] = nil
				end
			end
			servers[victim] = sim:server(`S{next}`, nil, libraries[victim])
			next += 1
		elseif where[key] then
			where[key]:leave(key)
			where[key] = nil
		else
			const target = servers[random:integer(1, #servers)]
			target:join(key)
			where[key] = target
		end
		sim:run(random:integer(1, 15))
	end
	for key, server in where do
		server:leave(key)
	end
	sim:run(900)
	return sim:finish()
end

--> A rollback: KeepBlox writes every key first, then only ProfileStore servers run.
function Mixed.rollback(seed: number): Simulation.Report
	const sim = Simulation.new(seed, KB)
	const kb = sim:server("KB", nil, KB)
	for index = 1, 5 do
		kb:join(`u_{index}`)
	end
	sim:run(90)
	for index = 1, 5 do
		kb:leave(`u_{index}`)
	end
	sim:run(30)
	const ps = sim:server("PS", nil, PS)
	for index = 1, 5 do
		ps:join(`u_{index}`)
	end
	sim:run(90)
	for index = 1, 5 do
		ps:leave(`u_{index}`)
	end
	sim:run(60)
	return sim:finish()
end

Mixed.byName = {
	profileStoreToKeepBlox = Mixed.profileStoreToKeepBlox,
	keepBloxToProfileStore = Mixed.keepBloxToProfileStore,
	profileStoreCrash = Mixed.profileStoreCrash,
	keepBloxCrash = Mixed.keepBloxCrash,
	rollout = Mixed.rollout,
	rollback = Mixed.rollback,
} :: { [string]: Scenarios.Scenario }

return Mixed
