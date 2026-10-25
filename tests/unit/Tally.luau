--!strict
--- A tally: counts every server adds to, summed across the game (src/Tally.luau, src/TallyCount.luau,
--- src/TallyShard.luau). What a game sees: the sum, its cost in writes, the watchers, the shutdown.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function open(world: World.World, name: string, options: KeepBlox.TallyOptions?): (KeepBlox.Tally, World.Server)
	const server = world:server({ name = name, players = 1 })
	const given: KeepBlox.TallyOptions = if options then table.clone(options) else {}
	given.services = server.services
	return KeepBlox.tally("Gives", given), server
end

--> The counts stored in every shard of `key`, summed.
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

--> How many writes the shards of the tally "Gives" take from now on.
const function writes(world: World.World): { n: number }
	const counted = { n = 0 }
	world.backend:observe(function(event)
		if event.store == "Gives/global" then
			counted.n += 1
		end
	end)
	return counted
end

Spec.test("Tally: each server's adds are summed for every server, its own at once and the others' once read", function()
	const world = World.new(1)
	const a = open(world, "A")
	const b, serverB = open(world, "B")
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 3)
		a:add("harvest", 2)
		Spec.equal(a:total("harvest"), 5)
		Spec.equal(stored(world, "harvest"), 0)
	end, 10)
	Sim.run(world.scheduler, "B", function()
		b:add("harvest", 4)
		-- the other server's adds are not written yet, nor read
		Spec.equal(b:total("harvest"), 4)
		serverB.services.clock.wait(90)
		Spec.equal(stored(world, "harvest"), 9)
		Spec.equal(b:read("harvest"), { ok = true, total = 9 })
		Spec.equal(b:total("harvest"), 9)
	end, 200)
	-- A never read: it knows its own only, though they are written
	Spec.equal(a:total("harvest"), 5)
	Spec.equal(a:total("other"), 0)
end)

Spec.test("Tally: a server writes one batch a turn, whatever the number of adds, and nothing with none", function()
	const world = World.new(2)
	const a, server = open(world, "A")
	const counted = writes(world)
	Sim.run(world.scheduler, "A", function()
		const clock = server.services.clock
		for _ = 1, 100 do
			a:add("harvest", 1)
			clock.wait(0.5)
		end
		clock.wait(20)
		Spec.equal(counted.n, 1)
		Spec.equal(stored(world, "harvest"), 100)
		clock.wait(120)
		Spec.equal(counted.n, 1)
		a:add("harvest", 1)
		clock.wait(60)
		Spec.equal(counted.n, 2)
		Spec.equal(stored(world, "harvest"), 101)
	end, 400)
end)

Spec.test("Tally: a watcher is told the total after its first read, on each change, and not once it leaves", function()
	const world = World.new(3)
	const a = open(world, "A")
	const b = open(world, "B")
	const told: { number } = {}
	local connection: any = nil
	Sim.run(world.scheduler, "B", function()
		b:add("harvest", 4)
	end, 70)
	-- B's batch landed at its first turn, before A watches: A's first read finds it
	Sim.run(world.scheduler, "A", function()
		connection = a:watch("harvest", function(total: number)
			table.insert(told, total)
		end)
	end, 71)
	Spec.equal(told, { 4 })
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 1)
	end, 72)
	Spec.equal(told, { 4, 5 })
	Sim.run(world.scheduler, "B", function()
		b:add("harvest", 2)
	end, 73)
	-- B writes at 120, A reads at its first turn, 130
	world.scheduler:run(140)
	Spec.equal(told, { 4, 5, 7 })
	Sim.run(world.scheduler, "A", function()
		connection:Disconnect()
		b:add("harvest", 1)
	end, 141)
	world.scheduler:run(400)
	Spec.equal(told, { 4, 5, 7 })
	Spec.equal(stored(world, "harvest"), 8)
	-- A read nothing since it left: B's last add is not in its total
	Spec.equal(a:total("harvest"), 7)
end)

Spec.test("Tally: a watcher that leaves before its first read is never told", function()
	const world = World.new(4)
	const a = open(world, "A")
	const told: { number } = {}
	Sim.run(world.scheduler, "A", function()
		const connection = a:watch("harvest", function(total: number)
			table.insert(told, total)
		end)
		connection:Disconnect()
		a:add("harvest", 2)
	end, 200)
	Spec.equal(told, {})
	Spec.equal(stored(world, "harvest"), 2)
end)

Spec.test("Tally: a server that closes writes what it added first; one that crashes loses it", function()
	const world = World.new(5)
	const a, serverA = open(world, "A")
	const c, serverC = open(world, "C")
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 3)
		for _, callback in serverA.closing do
			callback()
		end
		Spec.equal(stored(world, "harvest"), 3)
	end, 30)
	Sim.run(world.scheduler, "C", function()
		c:add("harvest", 2)
	end, 31)
	serverC:crash()
	world.scheduler:run(300)
	Spec.equal(stored(world, "harvest"), 3)
end)

Spec.test("Tally: a turn waits while the server's budget is nearly spent; a flush or a read does not", function()
	const world = World.new(6)
	const a = open(world, "A", { reserve = 100000 })
	const b, serverB = open(world, "B")
	const told: { number } = {}
	Sim.run(world.scheduler, "A", function()
		a:add("harvest", 1)
		a:watch("harvest", function(total: number)
			table.insert(told, total)
		end)
	end, 1)
	Sim.run(world.scheduler, "B", function()
		b:add("harvest", 4)
		serverB.services.clock.wait(200)
		-- A's turns wrote nothing and read nothing; B's wrote
		Spec.equal(stored(world, "harvest"), 4)
	end, 300)
	Spec.equal(told, { 1 })
	Sim.run(world.scheduler, "A", function()
		Spec.equal(a:flush(), true)
		Spec.equal(stored(world, "harvest"), 5)
		Spec.equal(a:read("harvest"), { ok = true, total = 5 })
	end, 400)
	Spec.equal(told, { 1, 5 })
end)

Spec.test("Tally: a key, an amount and the options are checked", function()
	const world = World.new(7)
	const a = open(world, "A")
	Spec.throws(function()
		a:add("harvest", 0 / 0)
	end, "a tally adds a finite number")
	Spec.throws(function()
		a:add("harvest", math.huge)
	end, "a tally adds a finite number")
	Spec.throws(function()
		a:add("harvest", "1" :: any)
	end, "a tally adds a finite number")
	Spec.throws(function()
		a:add(string.rep("k", 49), 1)
	end, "over the 50 characters")
	Spec.throws(function()
		a:add("", 1)
	end, "a tally's key is a string")
	a:add(string.rep("k", 48), 1)
	Spec.equal(a:total(string.rep("k", 48)), 1)
	Spec.throws(function()
		open(world, "B", { shards = 1.5 })
	end, "a tally's shards is a whole number")
	Spec.throws(function()
		open(world, "C", { interval = 0 })
	end, "a tally's interval is seconds above zero")
	Spec.throws(function()
		open(world, "D", { remember = -1 })
	end, "a tally's remember is seconds above zero")
end)

Spec.test("Tally: in memory, the counts are kept and summed, and nothing reaches the data store", function()
	const world = World.new(8)
	const server = world:server({ name = "A", players = 1 })
	const first = KeepBlox.tally("Gives", { services = server.services, mock = "tally-memory" })
	const second = KeepBlox.tally("Gives", { services = server.services, mock = "tally-memory" })
	Sim.run(world.scheduler, "A", function()
		first:add("harvest", 2)
		second:add("harvest", 3)
		Spec.equal(first:flush(), true)
		Spec.equal(second:flush(), true)
		Spec.equal(first:read("harvest"), { ok = true, total = 5 })
	end, 10)
	Spec.equal(stored(world, "harvest"), 0)
end)

return nil
