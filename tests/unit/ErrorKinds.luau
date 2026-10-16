--!strict
--- The third argument of `store.onError`: one word of a fixed list, never a key (src/Report.luau).
---
--- Each report of the library is checked with its kind where a spec already makes it happen (the
--- listeners there record `<key>: <message> [<kind>]`). This file holds the reports no other spec makes,
--- each beside the same call when nothing goes wrong, and a game's listener of two arguments.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const REJECTED = "502: API Services rejected request"

const function setup(options: { [string]: any }?): (World.World, World.Server, KeepBlox.Store, { string })
	const world = World.new(3)
	const server = world:server({ name = "A", players = 1 })
	const storeOptions: any = { template = { coins = 0 }, services = server.services }
	for key, value in options or {} do
		storeOptions[key] = value
	end
	const store = KeepBlox.store("Profiles", storeOptions)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string, kind: KeepBlox.ErrorKind)
		table.insert(errors, `{key}: {message} [{kind}]`)
	end)
	return world, server, store, errors
end

Spec.test("Error kinds: a listener of two arguments hears what one of three hears, without the kind", function()
	const world, server, store, errors = setup()
	const two: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(two, `{key}: {message}`)
	end)
	const counted: { [string]: number } = {}
	store.onError:connect(function(_: string, _: string, kind: KeepBlox.ErrorKind)
		counted[kind] = (counted[kind] or 0) + 1
	end)
	Sim.run(world.scheduler, "A", function()
		const fine = store:load("u_2")
		assert(fine.ok, "a profile loads")
		fine.profile:release()
		Spec.equal(errors, {}, "a load and a release report nothing")
		server.services.dataStores:GetDataStore("Profiles"):SetAsync("u_1", "legacy string")
		Spec.equal(store:load("u_1"), { ok = false, reason = "foreign" })
	end, 30)
	const QUARANTINED = "u_1: the stored value is not a profile; it was copied to quarantine and left untouched"
	Spec.equal(errors, { `{QUARANTINED} [quarantine]` })
	Spec.equal(two, { QUARANTINED })
	-- A game counts by kind: the key is in the message only.
	Spec.equal(counted, { quarantine = 1 })
end)

Spec.test("Error kinds: a grant that throws is a receipt's, and a grant that works reports nothing", function()
	const world, _, store, errors = setup()
	const decide = store:receipts({
		keyFor = function(userId: number): string
			return `u_{userId}`
		end,
		products = {
			[1] = function(profile: any)
				profile.Data.coins += 100
			end,
			[2] = function()
				error("out of stock", 0)
			end,
		},
	})
	Sim.run(world.scheduler, "A", function()
		const result = store:load("u_7")
		assert(result.ok, "loaded")
		Spec.equal(decide({ PlayerId = 7, PurchaseId = "r1", ProductId = 1 }), "PurchaseGranted")
		Spec.equal(errors, {}, "a grant that works")
		Spec.equal(decide({ PlayerId = 7, PurchaseId = "r2", ProductId = 2 }), "NotProcessedYet")
		result.profile:release()
	end, 30)
	Spec.equal(errors, { "u_7: the grant for product 2 failed: out of stock [receipt]" })
end)

Spec.test("Error kinds: a message refused, one not sent and a handler that throws are a message's", function()
	const world, server, store, errors = setup()
	Sim.run(world.scheduler, "A", function()
		Spec.equal(store:message("u_1", { gift = 1 }), { ok = true })
		Spec.equal(errors, {}, "a message sent")
		server.services.dataStores:GetDataStore("Profiles"):SetAsync("u_2", "legacy string")
		Spec.equal(store:message("u_2", { gift = 1 }), { ok = false, reason = "foreign" })
		world.faults:add({ op = "UpdateAsync", key = "u_3", error = REJECTED })
		Spec.equal(store:message("u_3", { gift = 1 }), { ok = false, reason = "failed" })
		world.faults:clear()
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		result.profile:onMessage(function()
			error("the handler broke", 0)
		end)
		world.scheduler:wait(1)
		result.profile:release()
	end, 120)
	Spec.equal(errors, {
		"u_2: message refused: the queue is foreign [message]",
		"u_3: message not sent: the data store kept failing [message]",
		"u_1: a message handler failed: the handler broke [message]",
	})
end)

Spec.test("Error kinds: a board not written is a leaderboard's, and one written reports nothing", function()
	const world, _, store, errors = setup({
		leaderboards = {
			coins = function(data: any): number?
				return data.coins
			end,
		},
	})
	Sim.run(world.scheduler, "A", function()
		const written = store:load("u_1")
		assert(written.ok, "loaded")
		written.profile.Data.coins = 5
		written.profile:release()
		world.scheduler:wait(2)
		Spec.equal(errors, {}, "a board written")
		world.faults:add({ op = "OrderedSetAsync", key = "u_2", error = REJECTED })
		const refused = store:load("u_2")
		assert(refused.ok, "loaded")
		refused.profile.Data.coins = 9
		refused.profile:release()
		world.scheduler:wait(2)
	end, 60)
	Spec.equal(world.ordered["Profiles__coins/global"], { u_1 = 5 })
	Spec.equal(errors, { `u_2: leaderboard coins not written: {REJECTED} [leaderboard]` })
end)

Spec.test("Error kinds: a failed read of the old store is an import's, with no key, and is tried again", function()
	const world, _, store, errors = setup({
		import = KeepBlox.importers.custom({
			name = "Old",
			fetch = function(services: any, key: string): (any, any)
				return services.dataStores:GetDataStore("Old"):GetAsync(key, false)
			end,
			read = function(value: any): any
				return if value == nil then { kind = "none" } else { kind = "data", data = value }
			end,
		}),
	})
	world.faults:add({ op = "GetAsync", error = REJECTED, times = 1 })
	Sim.run(world.scheduler, "A", function()
		const first = store:load("u_1")
		assert(first.ok, "loaded after the read was tried again")
		first.profile:release()
		const second = store:load("u_2")
		assert(second.ok, "loaded")
		second.profile:release()
	end, 60)
	Spec.equal(errors, { `: import read failed: {REJECTED} [import]` })
end)

return nil
