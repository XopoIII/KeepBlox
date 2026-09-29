--!strict
--- The vendored ProfileStore runs, unmodified, on the simulated engine: the baseline the harness
--- measures KeepBlox against.
const RobloxEnv = require("@sim/RobloxEnv")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const SOURCE = RobloxEnv.read("tests/reference/ProfileStore.luau")

Spec.test("Reference ProfileStore: a session loads, saves on end, and releases the lock", function()
	const world = World.new(1)
	const scheduler = world.scheduler
	const server = world:server({ name = "A", players = 1 })
	const env = RobloxEnv.new(world, server)
	local ended = false
	Sim.run(scheduler, "A", function()
		const ProfileStore = env:load(SOURCE, "ProfileStore")
		const store = ProfileStore.New("Profiles", { coins = 0 })
		const profile = store:StartSessionAsync("u_1")
		assert(profile, "the session starts")
		Spec.equal(profile.Data, { coins = 0 })
		profile.Data.coins = 25
		profile.OnSessionEnd:Connect(function()
			ended = true
		end)
		profile:EndSession()
	end, 60)
	Spec.equal(#scheduler.failures, 0, "no thread failed")
	Spec.equal(ended, true, "OnSessionEnd fired")
	const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(record.Data, { coins = 25 })
	Spec.equal(record.MetaData.ActiveSession, nil)
	Spec.equal(record.MetaData.SessionLoadCount, 1)
end)

return nil
