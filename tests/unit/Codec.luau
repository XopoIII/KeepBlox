--!strict
--- Compressed profiles (Codec): past 4 MB in memory, under it in the store (ProfileService#24,
--- ProfileStore#7, DocumentService#112).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const COMPRESS = { above = 100_000 }

const function stored(world: World.World, key: string): any
	return (world.backend:latest("Profiles/global", key) :: any).value
end

const function big(): { string }
	-- Six megabytes of play history: large, and as repetitive as real data is.
	const log = {}
	for index = 1, 60_000 do
		log[index] =
			`quest {index % 40} done at level {index % 97}, reward {index % 13} gems and a key ....................`
	end
	return log
end

const function open(world: World.World, name: string, compress: any): KeepBlox.Store
	const server = world:server({ name = name, players = 1 })
	return KeepBlox.store("Profiles", { template = { log = {} }, services = server.services, compress = compress })
end

Spec.test("Codec: a profile over 4 MB saves compressed and loads back exactly", function()
	const world = World.new(2)
	const a = open(world, "A", COMPRESS)
	const log = big()
	local errors = 0
	a.onError:connect(function()
		errors += 1
	end)
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.log = log
		Spec.equal(result.profile:save(), true)
		Spec.equal(#result.profile.LastSavedData.log, 60_000, "LastSavedData is the data, not its packing")
		result.profile:release()
	end, 120)
	Spec.equal(errors, 0)
	Spec.equal(stored(world, "u_1").Data.__KeepBlox, "zstd1")
	-- A server with compression turned off still reads it.
	const b = open(world, "B", nil)
	Sim.run(world.scheduler, "B", function()
		const result = b:load("u_1")
		assert(result.ok, "reloaded")
		Spec.equal(result.profile.Data.log, log)
		const versions = b:versions("u_1")
		Spec.equal(#b:readVersion("u_1", versions[#versions].version).log, 60_000)
	end, world.scheduler.now + 120)
end)

Spec.test("Codec: small data, and data holding buffers, are stored as they are", function()
	const world = World.new(2)
	const a = open(world, "A", COMPRESS)
	Sim.run(world.scheduler, "A", function()
		const small = a:load("u_small")
		assert(small.ok, "loaded")
		small.profile.Data.log = { "one entry" }
		small.profile:release()
		const buffered = a:load("u_buffer")
		assert(buffered.ok, "loaded")
		buffered.profile.Data.log = { string.rep("x", 200_000) }
		buffered.profile.Data.blob = buffer.create(16)
		buffered.profile:release()
	end, 120)
	Spec.equal(stored(world, "u_small").Data, { log = { "one entry" } })
	Spec.equal(stored(world, "u_buffer").Data.__KeepBlox, nil)
end)

Spec.test("Codec: data too large even compressed is refused, and the last save stays", function()
	const world = World.new(2)
	const a = open(world, "A", COMPRESS)
	const errors: { string } = {}
	a.onError:connect(function(_: string, message: string)
		table.insert(errors, message)
	end)
	-- Noise does not compress: six megabytes of it stay well over four.
	const random = world.scheduler.random
	const parts = table.create(6_000)
	for index = 1, 6_000 do
		const chars = table.create(1_000)
		for position = 1, 1_000 do
			chars[position] = string.char(random:integer(33, 126))
		end
		parts[index] = table.concat(chars)
	end
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "loaded")
		result.profile.Data.log = { "kept" }
		result.profile:save()
		result.profile.Data.log = parts
		result.profile:save()
		result.profile:release()
	end, 120)
	Spec.truthy(string.find(errors[1], "still over the 4194304 byte limit when compressed", 1, true) ~= nil, errors[1])
	Spec.equal(stored(world, "u_1").Data, { log = { "kept" } })
end)

Spec.test("Codec: compression needs a threshold", function()
	Spec.throws(function()
		KeepBlox.store(
			"P",
			{ template = {}, compress = {} :: any, services = World.new(1):server({ name = "A" }).services }
		)
	end, "compress needs `above`")
end)

return nil
