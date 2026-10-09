--!strict
--- A game may cancel a thread that is inside `store:load` (`task.cancel`, `coroutine.close`, its
--- script destroyed), at any point the load can park at. That ends the thread and nothing else: the
--- load is undone in a thread of the library's, the key is not left marked as opening or held without
--- a session, and a later load of it on the same server gets a session (src/Open.luau, src/Apart.luau,
--- src/Settle.luau; issue 31).
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

type Scene = LoadRig.Scene

const AFTERS: { LoadRig.After } = { "again", "alone", "close" }

-- Two players traded on server T, which died after the fourth write of the trade: "u_1" holds the
-- journal of a trade that was committed, which its next load must settle (500 coins less the 100).
const function trade(world: World.World)
	const server = world:server({ name = "T", players = 2 })
	const store = KeepBlox.store("Profiles", { template = LoadRig.TEMPLATE, services = server.services })
	Sim.run(world.scheduler, "T", function()
		const a = (store:load("u_1") :: any).profile
		assert((store:load("u_2") :: any).profile, "both loaded")
		a.Data.coins = 500
		assert(a:save(), "saved")
	end, 10)
	local writes = 0
	world.backend:observe(function()
		writes += 1
	end)
	world.scheduler:spawn(function()
		store:trade("u_1", "u_2", function(a: any, b: any)
			a.coins -= 100
			b.coins += 100
		end)
	end, "T")
	local running = true
	while running and writes < 4 do
		running = world.scheduler:step()
	end
	assert(writes == 4, "the trade's fourth write landed")
	assert(LoadRig.stored(world).MetaData.KeepBlox.trade ~= nil, "u_1 holds a journal")
	server:crash()
end

type Case = {
	name: string,
	build: () -> Scene,
	--> The coins the key holds for whoever loads it next.
	coins: number,
	--> Whether a cancel can find the key already held by A: the load parks after its claim landed (to
	--> store the dead owner's last beat, or to settle the trade).
	parksHolding: boolean,
}

const CASES: { Case } = {
	{
		name = "a key never stored",
		build = function(): Scene
			return LoadRig.scene(3)
		end,
		coins = 0,
		parksHolding = false,
	},
	{
		name = "a key another server holds and hands over",
		build = function(): Scene
			return LoadRig.scene(4, function(world: World.World)
				LoadRig.owner(world)
			end)
		end,
		coins = 6,
		parksHolding = false,
	},
	{
		name = "a key whose owner died with newer play in its last beat",
		build = function(): Scene
			return LoadRig.scene(5, function(world: World.World)
				LoadRig.owner(world):crash()
			end)
		end,
		coins = 6,
		parksHolding = true,
	},
	{
		name = "a key imported from another library",
		build = function(): Scene
			return LoadRig.scene(6, function(world: World.World)
				const old = world:server({ name = "old" })
				Sim.run(world.scheduler, "old", function()
					old.services.dataStores:GetDataStore("PlayerData"):SetAsync("u_1", {
						documentServiceSchemaVersion = 0,
						sessionLockId = "old",
						lockTimestamp = 0,
						isLocked = false,
						dataSchemaVersion = 1,
						lastCompatibleVersion = 1,
						data = { coins = 70 },
					})
				end, 2)
			end, { import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) })
		end,
		coins = 70,
		parksHolding = false,
	},
	{
		name = "a key with a trade its last server did not finish",
		build = function(): Scene
			return LoadRig.scene(7, trade)
		end,
		coins = 400,
		parksHolding = true,
	},
}

for _, case in CASES do
	for _, after in AFTERS do
		Spec.test(`Cancelled load: {case.name}, its caller cancelled at every point, then {after}`, function()
			const swept = LoadRig.sweep(case.build, after, case.coins)
			-- The load nobody cancelled is the one the others are measured against.
			Spec.equal(swept.result.ok, true, "the load nobody cancelled")
			Spec.equal(swept.result.profile.Data.coins, case.coins)
			Spec.equal(swept.cancels >= 3, true, `only {swept.cancels} cancels`)
			Spec.equal(swept.held > 0, case.parksHolding, `{swept.held} cancels found the key held`)
		end)
	end
end

return nil
