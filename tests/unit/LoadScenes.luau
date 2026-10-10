--!strict
--- The scenes a load of "u_1" on server A is swept through (tests/unit/CancelledLoad.luau,
--- LoadGivesUp.luau, LoadThrows.luau): what the key holds, and who holds it, before A loads it.
const KeepBlox = require("@keepblox")
const LoadRig = require("./LoadRig")
const Sim = require("./Sim")
const World = require("@fakes/World")

type Scene = LoadRig.Scene

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

export type Case = {
	name: string,
	--> The scene; `dress` gives A's store other services than its server's own.
	build: (dress: LoadRig.Dress?) -> Scene,
	--> The coins the key holds for whoever loads it next.
	coins: number,
	--> Whether a cancel can find the key already held by A: the load parks after its claim landed (to
	--> store the dead owner's last beat, or to settle the trade).
	parksHolding: boolean,
	--> Whether the key's last owner died with play only its last beat holds.
	lastBeat: boolean,
	--> Seconds within which another server gets the key once A has let go of it or never took it: a
	--> free key at its first request, a live owner's on its hand-over, a dead owner's once its beat
	--> has stood still for two beats (8 s). Never the lease (`death`, 605 s).
	within: number,
}

const CASES: { Case } = {
	{
		name = "a key never stored",
		build = function(dress: LoadRig.Dress?): Scene
			return LoadRig.scene(3, nil, nil, dress)
		end,
		coins = 0,
		parksHolding = false,
		lastBeat = false,
		within = 1,
	},
	{
		name = "a key another server holds and hands over",
		build = function(dress: LoadRig.Dress?): Scene
			return LoadRig.scene(4, function(world: World.World)
				LoadRig.owner(world)
			end, nil, dress)
		end,
		coins = 6,
		parksHolding = false,
		lastBeat = false,
		within = 4,
	},
	{
		name = "a key whose owner died with newer play in its last beat",
		build = function(dress: LoadRig.Dress?): Scene
			return LoadRig.scene(5, function(world: World.World)
				LoadRig.owner(world):crash()
			end, nil, dress)
		end,
		coins = 6,
		parksHolding = true,
		lastBeat = true,
		within = 10,
	},
	{
		name = "a key imported from another library",
		build = function(dress: LoadRig.Dress?): Scene
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
			end, { import = KeepBlox.importers.DocumentService({ store = "PlayerData" }) }, dress)
		end,
		coins = 70,
		parksHolding = false,
		lastBeat = false,
		within = 1,
	},
	{
		name = "a key with a trade its last server did not finish",
		build = function(dress: LoadRig.Dress?): Scene
			return LoadRig.scene(7, trade, nil, dress)
		end,
		coins = 400,
		parksHolding = true,
		lastBeat = false,
		within = 10,
	},
}

return CASES
