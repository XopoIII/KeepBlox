--!strict
--- Moving real data: each rival library (downloaded, unmodified) saves a player in the simulator, then
--- KeepBlox loads the same player through its importer and must hold exactly that data. Exits 1 on
--- any mismatch.
---
---     luneblox run bench/ImportCheck
const KeepBlox = require("@keepblox")
const RobloxEnv = require("@sim/RobloxEnv")
const World = require("@fakes/World")
const process = require("@lune/process")

type Case = { adapter: any, importer: any }

const CASES: { Case } = {
	{
		adapter = require("./adapters/DocumentServiceAdapter"),
		importer = KeepBlox.importers.DocumentService({ store = "Profiles" }),
	},
	{ adapter = require("./adapters/LapisAdapter"), importer = KeepBlox.importers.Lapis({ store = "Profiles" }) },
	{
		adapter = require("./adapters/DataStore2Adapter"),
		importer = KeepBlox.importers.DataStore2({
			name = "Profiles",
			userId = function(key: string): number?
				return tonumber(string.match(key, "%d+"))
			end,
		}),
	},
}

local failed = false
for _, case in CASES do
	const world = World.new(3)
	const old = world:server({ name = "Old", players = 1 })
	const env = RobloxEnv.new(world, old)
	local session: any = nil
	world.scheduler:spawn(function()
		const library = case.adapter.boot(env)
		session = library.open("u_7", {
			acked = function() end,
			ended = function() end,
			cancelled = function(): boolean
				return false
			end,
		})
		assert(session, `{case.adapter.name}: open failed`)
		session.data.p.played = 42
		session.data.p.bonus = 3
		session.release()
	end, "Old")
	world.scheduler:run(world.scheduler.now + 120)
	old:crash()
	const new = world:server({ name = "New", players = 1 })
	const store = KeepBlox.store("KeepBloxProfiles", {
		template = { p = {} },
		services = new.services,
		import = case.importer,
	})
	local got: any = nil
	world.scheduler:spawn(function()
		const result = store:load("u_7")
		got = if result.ok then result.profile.Data else result.reason
	end, "New")
	world.scheduler:run(world.scheduler.now + 300)
	const ok = type(got) == "table" and got.p.played == 42 and got.p.bonus == 3
	print(`{case.adapter.name}: {if ok then "imported" else `FAILED ({tostring(got)})`}`)
	failed = failed or not ok
end
process.exit(if failed then 1 else 0)
