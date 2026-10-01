--!strict
--- Taking over a crashed owner's key (Open, Recover), as the live load test found it failing.
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, gifts = {} }

const function store(world: World.World, name: string, config: { [string]: number }?): KeepBlox.Store
	return KeepBlox.store(
		"Profiles",
		{ template = TEMPLATE, services = world:server({ name = name }).services, config = config }
	)
end

-- A plays `u_1` for `seconds`, one coin a second, and dies; returns the coins played.
const function playThenCrash(world: World.World, a: KeepBlox.Store, seconds: number): number
	local played = 0
	Sim.run(world.scheduler, "A", function()
		const result = a:load("u_1")
		assert(result.ok, "A loaded")
		for _ = 1, seconds do
			world.scheduler:wait(1)
			played += 1
			result.profile.Data.coins = played
		end
	end, world.scheduler.now + seconds + 5)
	return played
end

const function crash(world: World.World, name: string)
	world.scheduler:crash(name)
	world.bus:disconnectServer(name)
end

const function reload(world: World.World, b: KeepBlox.Store): any
	local profile: any = nil
	Sim.run(world.scheduler, "B", function()
		const result = b:load("u_1")
		assert(result.ok, `B loaded ({(result :: any).reason})`)
		profile = result.profile
	end, world.scheduler.now + 120)
	return profile
end

-- Found by the live load test (GP_TEST, 2026-10-02): a server taking over a crashed owner's key reads
-- its snapshot from MemoryStore after the claim, and the key was no longer marked as opening by then.
-- A second load of the key on that server claimed it again: two live sessions of one profile, the
-- second with the stored data, and the first one's unsaved play lost.
Spec.test("Takeover: a key being recovered from a dead owner opens once on the server taking over", function()
	for seed = 1, 5 do
		const world = World.new(seed)
		playThenCrash(world, store(world, "A"), 50)
		crash(world, "A")
		const b = store(world, "B")
		const loaded: { any } = {}
		const refused: { [string]: number } = {}
		Sim.run(world.scheduler, "B", function()
			-- The game asks again every 50 ms for 30 s: a player rejoining while their load recovers.
			for _ = 1, 600 do
				world.scheduler:spawn(function()
					const result = b:load("u_1")
					if result.ok then
						table.insert(loaded, result.profile)
					else
						const reason = (result :: any).reason
						refused[reason] = (refused[reason] or 0) + 1
					end
				end, "B")
				world.scheduler:wait(0.05)
			end
		end, world.scheduler.now + 200)
		Spec.equal(#loaded, 1, `seed {seed}: the key opened once`)
		Spec.equal(refused, { open = 599 }, `seed {seed}: every other load was refused as open`)
	end
end)

-- Found by the live load test (GP_TEST, 2026-10-02): on a spent budget the one write that stores the
-- dead owner's snapshot failed, the stored data was used, and two minutes of play were lost.
Spec.test("Takeover: storing the dead owner's snapshot is tried again when the data store refuses it", function()
	for seed = 1, 5 do
		const world = World.new(seed)
		const played = playThenCrash(world, store(world, "A"), 100)
		crash(world, "A")
		-- B's data store refuses the three writes that follow its claim of the key.
		const real = world:server({ name = "B" }).services
		const services = table.clone(real :: any)
		local refuse = 0
		services.dataStores = setmetatable({
			GetDataStore = function(_: any, name: string, scope: string?): any
				const handle = real.dataStores:GetDataStore(name, scope)
				return setmetatable({
					UpdateAsync = function(_: any, key: string, transform: (...any) -> ...any): ...any
						if refuse > 0 then
							refuse -= 1
							error("502: API Services rejected request with error. HTTP 500 (Internal Server Error)", 0)
						end
						return handle:UpdateAsync(key, function(value: any, info: any): ...any
							const written = table.pack(transform(value, info))
							const session = type(written[1]) == "table" and written[1].MetaData.ActiveSession
							if type(session) == "table" and session[2] == "job-B" and refuse == 0 then
								refuse = 3
							end
							return table.unpack(written, 1, written.n)
						end)
					end,
				}, { __index = handle })
			end,
		}, { __index = real.dataStores })
		const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = services })
		const coins = reload(world, b).Data.coins
		Spec.truthy(played - coins <= 5, `seed {seed}: played {played}, got {coins}`)
	end
end)

return nil
