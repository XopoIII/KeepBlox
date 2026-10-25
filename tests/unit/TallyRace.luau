--!strict
--- A tally under faults: a batch counted once though its write failed after landing, ran late or was
--- settled by a read; a shard holding something else; many servers on one shard (src/Tally.luau,
--- src/TallyCount.luau, src/TallyShard.luau).
const Errors = require("@fakes/Errors")
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const TallyCount = require("@keepblox/TallyCount")
const TallyShard = require("@keepblox/TallyShard")
const World = require("@fakes/World")

const function open(world: World.World, name: string, options: KeepBlox.TallyOptions?): (KeepBlox.Tally, World.Server)
	const server = world:server({ name = name, players = 1 })
	const given: KeepBlox.TallyOptions = if options then table.clone(options) else {}
	given.services = server.services
	return KeepBlox.tally("Gives", given), server
end

const function stored(world: World.World, key: string, shards: number?): number
	local sum = 0
	for shard = 1, shards or 8 do
		const latest = world.backend:latest("Gives/global", `{key}/{shard}`)
		if latest then
			sum += latest.value.count
		end
	end
	return sum
end

const function kinds(tally: KeepBlox.Tally): { string }
	const heard: { string } = {}
	tally.onError:connect(function(_key: string, _message: string, kind: string)
		table.insert(heard, kind)
	end)
	return heard
end

Spec.test("Tally: a batch whose write landed and then failed is counted once", function()
	const world = World.new(21)
	const a = open(world, "A")
	const heard = kinds(a)
	world.faults:add({ op = "UpdateAsync", server = "A", times = 1, error = Errors.rejected(), after = true })
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 5)
		Spec.equal(a:flush(), false)
		Spec.equal(stored(world, "harvest"), 5)
		Spec.equal(a:total("harvest"), 5)
		Spec.equal(a:flush(), true)
		Spec.equal(stored(world, "harvest"), 5)
		Spec.equal(a:read("harvest"), { ok = true, total = 5 })
		a:add("harvest", 2)
		Spec.equal(a:flush(), true)
		Spec.equal(stored(world, "harvest"), 7)
	end, 60)
	Spec.equal(heard, { "tally" })
end)

Spec.test("Tally: a batch that seemed to fail is settled by a read, and not written again", function()
	const world = World.new(22)
	const a = open(world, "A")
	local writes = 0
	world.backend:observe(function()
		writes += 1
	end)
	world.faults:add({ op = "UpdateAsync", server = "A", times = 1, error = Errors.rejected(), after = true })
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 5)
		Spec.equal(a:flush(), false)
		Spec.equal(writes, 1)
		Spec.equal(a:read("harvest"), { ok = true, total = 5 })
		Spec.equal(a:total("harvest"), 5)
		Spec.equal(a:flush(), true)
		Spec.equal(writes, 1)
	end, 60)
end)

Spec.test("Tally: a try held past its timeout lands late on the batch its retry wrote, and adds nothing", function()
	const world = World.new(23)
	const a, server = open(world, "A")
	world.faults:add({ op = "UpdateAsync", server = "A", times = 1, delay = 30 })
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 5)
		Spec.equal(a:flush(), false)
		Spec.equal(a:flush(), true)
		Spec.equal(stored(world, "harvest"), 5)
		server.services.clock.wait(30)
		Spec.equal(stored(world, "harvest"), 5)
		a:add("harvest", 2)
		Spec.equal(a:flush(), true)
		Spec.equal(stored(world, "harvest"), 7)
	end, 120)
end)

Spec.test("Tally: a try run after its server's entry was forgotten changes nothing", function()
	const world = World.new(24)
	const options: KeepBlox.TallyOptions = { shards = 1, remember = 100 }
	const a = open(world, "A", options)
	const b, serverB = open(world, "B", options)
	-- A's first try is held 150 seconds; its retry lands at once, and B's write at 130 forgets A's entry
	world.faults:add({ op = "UpdateAsync", server = "A", times = 1, delay = 150 })
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 5)
		Spec.equal(a:flush(), false)
		Spec.equal(a:flush(), true)
	end, 25)
	Sim.run(world.scheduler, "B", function()
		serverB.services.clock.wait(130 - world.scheduler.now)
		b:add("harvest", 1)
		Spec.equal(b:flush(), true)
		const servers = (world.backend:latest("Gives/global", "harvest/1") :: any).value.servers
		local entries = 0
		for _ in servers do
			entries += 1
		end
		Spec.equal(entries, 1)
	end, 300)
	Spec.equal(stored(world, "harvest", 1), 6)
end)

Spec.test("Tally: a read's answer older than what a write saw is not taken", function()
	const world = World.new(26)
	const a, server = open(world, "A", { shards = 1 })
	-- the read finds the shard empty, and its answer comes back ten seconds later
	world.faults:add({ op = "GetAsync", server = "A", times = 1, delay = 10, after = true })
	local answer: any = nil
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 5)
		server.services.clock.spawn(function()
			answer = a:read("harvest")
		end)
		server.services.clock.wait(1)
		Spec.equal(a:flush(), true)
		Spec.equal(a:total("harvest"), 5)
		server.services.clock.wait(15)
		Spec.equal(a:total("harvest"), 5)
	end, 60)
	Spec.equal(answer, { ok = true, total = 5 })
	Spec.equal(stored(world, "harvest", 1), 5)
end)

Spec.test("Tally: a shard holding something else is left as it is, counted by no one, and told once", function()
	const world = World.new(25)
	const a = open(world, "A", { shards = 1 })
	const heard = kinds(a)
	world.backend:write("Gives/global", "harvest/1", "junk", {}, {}, world.epoch * 1000)
	Sim.run(world.scheduler, "A", function()
		const answer = a:read("harvest") :: any
		Spec.equal({ answer.ok, answer.reason }, { false, "foreign" })
		Spec.equal(a:read("harvest").ok, false)
		a:add("harvest", 1)
		Spec.equal(a:flush(), false)
		Spec.equal(a:flush(), false)
		Spec.equal(a:total("harvest"), 1)
	end, 60)
	Spec.equal((world.backend:latest("Gives/global", "harvest/1") :: any).value, "junk")
	Spec.equal(heard, { "tally", "tally" })
end)

Spec.test("Tally: many servers adding at random on one shard lose nothing and count nothing twice", function()
	for seed = 31, 36 do
		const world = World.new(seed)
		world.faults.latency = { min = 0.05, max = 3 }
		local added, adds = 0, 0
		const tallies: { KeepBlox.Tally } = {}
		for index = 1, 6 do
			const tally, server = open(world, `S{index}`, { shards = 1, interval = 7 })
			table.insert(tallies, tally)
			world.scheduler:spawn(function()
				const random = world.scheduler.random
				for _ = 1, 20 do
					const amount = random:integer(1, 9)
					added += amount
					adds += 1
					tally:add("harvest", amount)
					server.services.clock.wait(random:integer(1, 5))
				end
			end, `S{index}`)
		end
		world.scheduler:run(400)
		-- every thread ran to its end: a spawn outside Sim.run fails quietly otherwise
		Spec.equal(#world.scheduler.failures, 0, `seed {seed} failures`)
		Spec.equal(adds, 120, `seed {seed} adds`)
		Spec.equal(stored(world, "harvest", 1), added, `seed {seed}`)
		Sim.run(world.scheduler, "S1", function()
			Spec.equal(tallies[1]:read("harvest"), { ok = true, total = added }, `seed {seed} read`)
		end, 500)
	end
end)

Spec.test("TallyShard: a batch lands once, only a newer serial adds, and silent servers' entries go", function()
	const first = TallyShard.add(nil, "s1", 1, 5, 1000, 100) :: TallyShard.Stored
	Spec.equal(first, { tally = 1, count = 5, version = 1, servers = { s1 = { 1, 1000 } } })
	Spec.equal(TallyShard.add(first, "s1", 1, 5, 1001, 100), nil)
	const second = TallyShard.add(first, "s2", 1, 3, 1050, 100) :: TallyShard.Stored
	Spec.equal(second, { tally = 1, count = 8, version = 2, servers = { s1 = { 1, 1000 }, s2 = { 1, 1050 } } })
	const third = TallyShard.add(second, "s1", 2, 1, 1120, 100) :: TallyShard.Stored
	Spec.equal(third, { tally = 1, count = 9, version = 3, servers = { s1 = { 2, 1120 }, s2 = { 1, 1050 } } })
	Spec.equal(TallyShard.add(third, "s1", 1, 5, 1121, 100), nil)
	-- s2 has been silent 150 seconds of the 100 remembered: its entry goes, s1's stays
	const fourth = TallyShard.add(third, "s3", 1, 1, 1200, 100) :: TallyShard.Stored
	Spec.equal(fourth.servers, { s1 = { 2, 1120 }, s3 = { 1, 1200 } })
	Spec.equal(TallyShard.seen(fourth, "s1"), { count = 10, version = 4, serial = 2 })
	Spec.equal(TallyShard.seen(fourth, "s2"), { count = 10, version = 4, serial = nil })
end)

Spec.test("TallyShard: nothing stored is an empty shard, anything not a shard is foreign", function()
	Spec.equal(TallyShard.classify(nil), "empty")
	Spec.equal(TallyShard.seen(nil, "s1"), { count = 0, version = 0, serial = nil })
	Spec.equal(TallyShard.classify({ tally = 1, count = 0, version = 0, servers = {} }), "shard")
	Spec.equal(TallyShard.classify({ tally = 2, count = 0, version = 0, servers = {} }), "foreign")
	Spec.equal(TallyShard.classify({ tally = 1, count = "0", version = 0, servers = {} }), "foreign")
	Spec.equal(TallyShard.classify({ tally = 1, count = 0, servers = {} }), "foreign")
	Spec.equal(TallyShard.classify({ tally = 1, count = 0, version = 0 }), "foreign")
	Spec.equal(TallyShard.classify("junk"), "foreign")
	Spec.equal(TallyShard.seen("junk", "s1"), nil)
end)

Spec.test("TallyCount: a server writes one shard, the same each time, and servers spread over them all", function()
	const hits: { [number]: number } = {}
	for index = 1, 400 do
		const shard = TallyCount.pick(`server-{index}`, 8)
		Spec.truthy(shard >= 1 and shard <= 8 and shard % 1 == 0, `shard {shard}`)
		Spec.equal(TallyCount.pick(`server-{index}`, 8), shard)
		hits[shard] = (hits[shard] or 0) + 1
	end
	for shard = 1, 8 do
		Spec.truthy((hits[shard] or 0) >= 25, `shard {shard} took {hits[shard]} of 400`)
	end
	Spec.equal(TallyCount.pick("server-1", 1), 1)
end)

return nil
