--!strict
--- Shared documents with no session lock, changed by any server (Lapis#58, DocumentService#89,
--- ProfileStore thread p3 #55-59).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { bank = 0, members = {} }

const function open(world: World.World, name: string): (KeepBlox.SharedStore, World.Server)
	const server = world:server({ name = name, players = 1 })
	return KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services }), server
end

Spec.test("Shared: updates from three servers at once all land", function()
	const world = World.new(4)
	const stores = {}
	for _, name in { "A", "B", "C" } do
		stores[name] = (open(world, name))
	end
	local failed = 0
	for name, store in stores do
		for _ = 1, 10 do
			world.scheduler:spawn(function()
				if not store:update("g_1", function(data: any)
					data.bank += 1
				end).ok then
					failed += 1
				end
			end, name)
		end
	end
	world.scheduler:run(world.scheduler.now + 300)
	Spec.equal(failed, 0)
	Spec.equal((world.backend:latest("Guilds/global", "g_1") :: any).value.Data.bank, 30)
end)

Spec.test("Shared: a missing document reads as the template; a failed change writes nothing", function()
	const world = World.new(4)
	const store = open(world, "A")
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:read("g_2"), { ok = true, data = TEMPLATE })
		Spec.equal(
			store:update("g_2", function(data: any)
				data.bank = 0 / 0
			end),
			{ ok = false, reason = "refused", message = "Data.bank: NaN cannot be stored" }
		)
		Spec.equal(
			store:update("g_2", function()
				error("no such member", 0)
			end),
			{ ok = false, reason = "error", message = "no such member" }
		)
	end, 60)
	Spec.equal(world.backend:latest("Guilds/global", "g_2"), nil)
end)

Spec.test("Shared: a profile's key is refused, so a session lock is never broken", function()
	const world = World.new(4)
	const server = world:server({ name = "A", players = 1 })
	const profiles = KeepBlox.store("Guilds", { template = TEMPLATE, services = server.services })
	const shared = KeepBlox.shared("Guilds", { template = TEMPLATE, services = server.services })
	Sim.run(world.scheduler, "A", function()
		assert((profiles:load("u_1") :: any).ok, "a profile holds the key")
		const result = shared:update("u_1", function(data: any)
			data.bank = 1
		end)
		Spec.equal(result.ok, false)
		Spec.equal((result :: any).reason, "locked")
	end, 30)
end)

Spec.test("Shared: watchers on other servers hear about each update", function()
	const world = World.new(4)
	const a = open(world, "A")
	const b = open(world, "B")
	local seen: any = nil
	Sim.run(world.scheduler, "B", function()
		b:watch("g_1", function(data: any)
			seen = data.bank
		end)
	end, 5)
	Sim.run(world.scheduler, "A", function()
		a:update("g_1", function(data: any)
			data.bank = 70
		end)
	end, world.scheduler.now + 10)
	Spec.equal(seen, 70)
end)

-- Studio and live data (see src/Studio.luau): the messages are the engine's. Memory outlives a world (it
-- is the server's, see MockServices), so each spec here names a store of its own.
const UNPUBLISHED = "You must publish this place to the web to access DataStore."

const function services(world: World.World, isStudio: boolean, refusal: string?, server: string?): any
	const made: any = table.clone(world:server({ name = server or "A", players = 1 }).services)
	made.isStudio = isStudio
	if refusal then
		made.dataStores = table.clone(made.dataStores)
		made.dataStores.GetDataStore = function()
			error(refusal, 0)
		end
		-- Nothing of the engine's may be leaned on there: the documents and their watchers are in memory.
		made.messaging = {
			PublishAsync = function()
				error(refusal, 0)
			end,
			SubscribeAsync = function()
				error(refusal, 0)
			end,
		}
	end
	return made
end

-- Updates and reads a document, watched, and returns what `onError` said and what reached the backend.
const function play(world: World.World, store: KeepBlox.SharedStore): ({ string }, { string }, any)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}|{message}`)
	end)
	const written: { string } = {}
	world.backend:observe(function(event)
		table.insert(written, `{event.store} {event.key}`)
	end)
	local watched: any = nil
	Sim.run(world.scheduler, "A", function()
		store:watch("g_1", function(data: any)
			watched = data.bank
		end)
		Spec.equal(store:read("g_1"), { ok = true, data = TEMPLATE })
		for bank = 1, 2 do
			const result = store:update("g_1", function(data: any)
				data.bank += 1
			end)
			Spec.equal(result, { ok = true, data = { bank = bank, members = {} } })
		end
		Spec.equal(store:read("g_1"), { ok = true, data = { bank = 2, members = {} } })
	end, 120)
	return errors, written, watched
end

Spec.test("Shared: Studio in a place never published keeps documents in memory and says so once", function()
	const world = World.new(4)
	const store = KeepBlox.shared("Unpublished", { template = TEMPLATE, services = services(world, true, UNPUBLISHED) })
	const errors, written, watched = play(world, store)
	Spec.equal(errors, { "|This place is not published: profiles are kept in memory, and nothing is saved" })
	Spec.equal(written, {})
	Spec.equal(watched, 2, "a watcher hears the updates made in memory")
end)

Spec.test("Shared: Studio without API access falls back to memory after a read-only check, once", function()
	const world = World.new(4)
	world.faults:add({ error = "403: Cannot write to DataStore from studio if API access is not enabled." })
	const store = KeepBlox.shared("NoAccess", { template = TEMPLATE, services = services(world, true) })
	const errors, written = play(world, store)
	Spec.equal(errors, { "|Studio has no API access: profiles are kept in memory, and nothing is saved" })
	Spec.equal(written, {})
end)

-- Whichever call comes first finds out: each of them asks before it touches the data store.
const FIRST: { [string]: (store: KeepBlox.SharedStore) -> () } = {
	read = function(store: KeepBlox.SharedStore)
		Spec.equal(store:read("g_1"), { ok = true, data = TEMPLATE })
	end,
	update = function(store: KeepBlox.SharedStore)
		Spec.equal(store:update("g_1", function() end), { ok = true, data = TEMPLATE })
	end,
	watch = function(store: KeepBlox.SharedStore)
		store:watch("g_1", function() end)
	end,
}
for name, call in FIRST do
	Spec.test(`Shared: Studio without API access is found by the first call, a {name}`, function()
		const world = World.new(4)
		world.faults:add({ error = "403: Cannot write to DataStore from studio if API access is not enabled." })
		const store = KeepBlox.shared(`First_{name}`, { template = TEMPLATE, services = services(world, true) })
		const errors: { string } = {}
		store.onError:connect(function(key: string, message: string)
			table.insert(errors, `{key}|{message}`)
		end)
		local took = math.huge
		Sim.run(world.scheduler, "A", function()
			const started = world.scheduler.now
			call(store)
			took = world.scheduler.now - started
		end, 120)
		Spec.equal(errors, { "|Studio has no API access: profiles are kept in memory, and nothing is saved" })
		Spec.truthy(took < 2, `one refused read, no retries ({took} s)`)
	end)
end

Spec.test("Shared: Studio with access uses the live store and reports nothing", function()
	const world = World.new(4)
	const store = KeepBlox.shared("Reached", { template = TEMPLATE, services = services(world, true) })
	const errors, written, watched = play(world, store)
	Spec.equal(errors, {})
	Spec.equal(written, { "Reached/global g_1", "Reached/global g_1" })
	Spec.equal(watched, 2)
end)

Spec.test(
	"Shared: a live server that cannot get its data store fails, and so does Studio on any other error",
	function()
		const world = World.new(4)
		Spec.throws(function()
			KeepBlox.shared("Guilds", { template = TEMPLATE, services = services(world, false, UNPUBLISHED) })
		end, UNPUBLISHED)
		Spec.throws(function()
			KeepBlox.shared(
				"Guilds",
				{ template = TEMPLATE, services = services(world, true, "DataStore name is too long", "B") }
			)
		end, "DataStore name is too long")
	end
)

Spec.test("Shared: a live server refused by the data store reports the failure and never moves to memory", function()
	const world = World.new(4)
	world.faults:add({ error = "403: Forbidden" })
	const store = KeepBlox.shared("Guilds", {
		template = TEMPLATE,
		services = services(world, false),
		config = { loadTimeout = 5 },
	})
	local result: any = nil
	Sim.run(world.scheduler, "A", function()
		result = store:update("g_1", function(data: any)
			data.bank = 1
		end)
	end, 120)
	Spec.equal(result, { ok = false, reason = "failed", message = "403: Forbidden" })
end)

return nil
