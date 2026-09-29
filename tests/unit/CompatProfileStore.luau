--!strict
--- The ProfileStore API over KeepBlox: names, signatures, signals and their order, as a game sees them.
const CompatAdapter = require("@sim/CompatAdapter")
const CompatProfileStore = require("@keepblox/Compat/ProfileStore")
const Scenarios = require("@sim/Scenarios")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0, settings = { music = true } }

const function setup(): (World.World, World.Server, any)
	const world = World.new(1)
	const server = world:server({ name = "A" })
	return world, server, CompatProfileStore.withServices(server.services)
end

Spec.test("Compat API: game code written for ProfileStore runs every scenario unchanged", function()
	for name, scenario in Scenarios.byName do
		const result = Scenarios.soak(scenario, CompatAdapter, 3)
		Spec.equal(result.violations, {}, `{name}: violations`)
		Spec.equal(result.failures, {}, `{name}: failures`)
	end
end)

Spec.test("Compat API: a session, its signals in ProfileStore's order, and its end", function()
	const world, _, ProfileStore = setup()
	const events: { string } = {}
	Sim.run(world.scheduler, "A", function()
		const store = ProfileStore.New("PlayerStore", TEMPLATE)
		const profile = store:StartSessionAsync("u_1", {
			Cancel = function(): boolean
				return false
			end,
		})
		assert(profile, "the session starts")
		Spec.equal(profile.Data, { coins = 0, settings = { music = true } })
		Spec.equal(profile.SessionLoadCount, 1)
		Spec.equal(profile:IsActive(), true)
		profile.OnSave:Connect(function()
			table.insert(events, "OnSave")
		end)
		profile.OnLastSave:Connect(function(reason: string)
			table.insert(events, `OnLastSave {reason}`)
		end)
		profile.OnSessionEnd:Connect(function()
			table.insert(events, "OnSessionEnd")
		end)
		profile.OnAfterSave:Connect(function(saved: any)
			table.insert(events, `OnAfterSave {saved.coins}`)
		end)
		profile.Data.coins = 3
		profile:EndSession()
		Spec.equal(profile:IsActive(), false, "inactive at once")
	end, 60)
	Spec.equal(events, { "OnSave", "OnLastSave Manual", "OnSessionEnd", "OnAfterSave 3" })
end)

Spec.test("Compat API: Reconcile fills what is missing and keeps what is there", function()
	const world, server, ProfileStore = setup()
	Sim.run(world.scheduler, "A", function()
		server.services.dataStores:GetDataStore("PlayerStore"):SetAsync("u_1", {
			Data = { coins = 9 },
			MetaData = { SessionLoadCount = 0, MetaTags = {} },
			GlobalUpdates = { 0, {} },
		})
		const profile = ProfileStore.New("PlayerStore", TEMPLATE):StartSessionAsync("u_1")
		profile:Reconcile()
		Spec.equal(profile.Data, { coins = 9, settings = { music = true } })
		profile:EndSession()
	end, 60)
end)

Spec.test("Compat API: GetAsync reads without a session; SetAsync overwrites and clears the lock", function()
	const world, _, ProfileStore = setup()
	Sim.run(world.scheduler, "A", function()
		const store = ProfileStore.New("PlayerStore", TEMPLATE)
		Spec.equal(store:GetAsync("nobody"), nil)
		const active = store:StartSessionAsync("u_1")
		active.Data.coins = 5
		active:EndSession()
		world.scheduler:wait(5)
		const view = store:GetAsync("u_1")
		Spec.equal(view.Data.coins, 5)
		Spec.equal(view:IsActive(), false)
		Spec.throws(function()
			view:Save()
		end, "can't save a profile in view mode")
		view.Data.coins = 50
		view:SetAsync()
		Spec.equal(store:GetAsync("u_1").Data.coins, 50)
		Spec.equal(store:RemoveAsync("u_1"), true)
		Spec.equal(store:GetAsync("u_1"), nil)
	end, 60)
end)

Spec.test("Compat API: Mock stores are separate from the live ones", function()
	const world, _, ProfileStore = setup()
	const writes = {}
	world.backend:observe(function(event)
		table.insert(writes, event.key)
	end)
	Sim.run(world.scheduler, "A", function()
		const store = ProfileStore.New("PlayerStore", TEMPLATE)
		const mocked = store.Mock:StartSessionAsync("u_1")
		mocked.Data.coins = 7
		mocked:EndSession()
		world.scheduler:wait(5)
		Spec.equal(store.Mock:GetAsync("u_1").Data.coins, 7)
		Spec.equal(store:GetAsync("u_1"), nil)
	end, 60)
	Spec.equal(writes, {})
end)

Spec.test("Compat API: SetConstant accepts ProfileStore's names and refuses others", function()
	const _, _, ProfileStore = setup()
	ProfileStore.SetConstant("AUTO_SAVE_PERIOD", 60)
	ProfileStore.SetConstant("SESSION_STEAL", 20)
	Spec.throws(function()
		ProfileStore.SetConstant("NOT_A_CONSTANT", 1)
	end, 'unknown constant "NOT_A_CONSTANT"')
end)

Spec.test("Compat API: IsClosing turns true on shutdown", function()
	const world, server, ProfileStore = setup()
	Sim.run(world.scheduler, "A", function()
		ProfileStore.New("PlayerStore", TEMPLATE):StartSessionAsync("u_1")
		Spec.equal(ProfileStore.IsClosing, false)
		for _, callback in server.closing do
			callback()
		end
		Spec.equal(ProfileStore.IsClosing, true)
	end, 60)
end)

return nil
