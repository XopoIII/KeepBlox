--!strict
--- ProfileStore and KeepBlox side by side (.claude/plan/04-compat.md): no data rule broken in any mix,
--- keys readable both ways, and the questions the plan listed to verify first, answered here.
const KeepBlox = require("@keepblox")
const KeepBloxAdapter = require("@sim/KeepBloxAdapter")
const Mixed = require("@sim/Mixed")
const Scenarios = require("@sim/Scenarios")
const Sim = require("../unit/Sim")
const Simulation = require("@sim/Simulation")
const Spec = require("../Spec")
const World = require("@fakes/World")

const SEEDS = 5

const function soak(name: string): Scenarios.Soak
	const result = Scenarios.soak(Mixed.byName[name], KeepBloxAdapter.default, SEEDS)
	Spec.equal(result.violations, {}, `{name}: violations`)
	Spec.equal(result.failures, {}, `{name}: thread failures`)
	return result
end

Spec.test("Compat: a session hands over between the libraries, both ways, losing nothing", function()
	for _, name in { "profileStoreToKeepBlox", "keepBloxToProfileStore", "rollback" } do
		const metrics = soak(name).metrics
		Spec.equal(metrics.maxProgressLost, 0, `{name}: progress lost`)
		Spec.equal(metrics.maxStaleSeconds, 0, `{name}: stale seconds`)
		Spec.truthy(metrics.maxOpenSeconds < 10, `{name}: open took {metrics.maxOpenSeconds} s`)
	end
end)

Spec.test("Compat: a crashed owner of either library is taken over by ProfileStore's rules", function()
	for _, name in { "profileStoreCrash", "keepBloxCrash" } do
		const metrics = soak(name).metrics
		-- ProfileStore's SESSION_STEAL is 40 s after the first request, plus the polls around it.
		Spec.truthy(metrics.maxOpenSeconds >= 40 and metrics.maxOpenSeconds < 50, `{name}: {metrics.maxOpenSeconds} s`)
	end
	Spec.truthy(
		soak("keepBloxCrash").metrics.maxProgressLost <= KeepBlox.defaults.renew,
		"a KeepBlox owner loses one renewal"
	)
end)

Spec.test("Compat: a rolling migration with crashes keeps every invariant", function()
	soak("rollout")
end)

Spec.test("Compat: ProfileStore keeps our MetaData.KeepBlox when it rewrites a key", function()
	const report = Mixed.rollback(1)
	Spec.equal(report.violations, {})
	-- Rerun the story and read the records it leaves.
	const sim = Simulation.new(1, KeepBloxAdapter.default)
	const kb = sim:server("KB")
	kb:join("u_1")
	sim:run(40)
	kb:leave("u_1")
	sim:run(20)
	const ProfileStoreAdapter = require("@sim/ProfileStoreAdapter")
	const ps = sim:server("PS", nil, ProfileStoreAdapter)
	ps:join("u_1")
	sim:run(40)
	ps:leave("u_1")
	sim:run(30)
	const record = (sim.world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(type(record.MetaData.KeepBlox), "table")
	Spec.truthy(record.MetaData.KeepBlox.lease >= 1, "our lease survived")
	Spec.equal(record.MetaData.SessionLoadCount, 2)
end)

Spec.test("Compat: messages cross between the libraries, both ways, handled once", function()
	const RobloxEnv = require("@sim/RobloxEnv")
	const source = RobloxEnv.read("tests/reference/ProfileStore.luau")
	const world = World.new(1)
	const psServer = world:server({ name = "PS" })
	const kbServer = world:server({ name = "KB" })
	const env = RobloxEnv.new(world, psServer)
	const kbStore = KeepBlox.store("Profiles", { template = { gifts = 0 }, services = kbServer.services })
	local psStore: any = nil
	local psProfile: any = nil
	Sim.run(world.scheduler, "PS", function()
		psStore = env:load(source, "ProfileStore").New("Profiles", { gifts = 0 })
		psProfile = psStore:StartSessionAsync("held_by_ps")
		psProfile:MessageHandler(function(message: any, processed: () -> ())
			psProfile.Data.gifts += message.amount
			processed()
		end)
	end, 5)
	local kbProfile: any = nil
	Sim.run(world.scheduler, "KB", function()
		const result = kbStore:load("held_by_kb")
		assert(result.ok, "loaded")
		const profile = result.profile
		kbProfile = profile
		profile:onMessage(function(message: any, processed: () -> ())
			profile.Data.gifts += message.amount
			processed()
		end)
		Spec.equal(kbStore:message("held_by_ps", { amount = 3 }), { ok = true })
	end, 10)
	Sim.run(world.scheduler, "PS", function()
		Spec.equal(psStore:MessageAsync("held_by_kb", { amount = 4 }), true)
	end, world.scheduler.now + 30)
	Spec.equal(psProfile.Data.gifts, 3, "ProfileStore handled KeepBlox's message")
	Spec.equal(kbProfile.Data.gifts, 4, "KeepBlox handled ProfileStore's message")
	world.scheduler:run(world.scheduler.now + 60)
	Spec.equal(psProfile.Data.gifts, 3, "once")
	Spec.equal(kbProfile.Data.gifts, 4, "once")
end)

Spec.test("Compat: a ProfileService-era lock (no GUID) is honoured, and taken over by ProfileStore's rules", function()
	const world = World.new(1)
	const services = world:server({ name = "A" }).services
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	Sim.run(world.scheduler, "A", function()
		const legacy = services.dataStores:GetDataStore("Profiles")
		legacy:SetAsync("u_1", {
			Data = { coins = 7 },
			MetaData = {
				ProfileCreateTime = 0,
				SessionLoadCount = 3,
				ActiveSession = { 1, "old-job" },
				LastUpdate = services.clock.time(),
				MetaTags = {},
			},
			GlobalUpdates = { 0, {} },
		})
		const started = world.scheduler.now
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		const waited = world.scheduler.now - started
		Spec.truthy(waited >= 40 and waited < 50, `taken over after {waited} s`)
		Spec.equal(result.profile.Data, { coins = 7 })
		Spec.equal(result.profile.loadCount, 4)
		result.profile:release()
	end, 120)
end)

Spec.test("Compat: a ProfileService-era lock that is long dead is taken over at once", function()
	const world = World.new(1)
	const services = world:server({ name = "A" }).services
	const store = KeepBlox.store("Profiles", { template = { coins = 0 }, services = services })
	Sim.run(world.scheduler, "A", function()
		services.dataStores:GetDataStore("Profiles"):SetAsync("u_1", {
			Data = { coins = 1 },
			MetaData = {
				SessionLoadCount = 1,
				ActiveSession = { 1, "old-job" },
				LastUpdate = services.clock.time() - 700,
			},
			GlobalUpdates = { 0, {} },
		})
		const started = world.scheduler.now
		const result = store:load("u_1")
		assert(result.ok, "loaded")
		Spec.truthy(world.scheduler.now - started < 5, `took {world.scheduler.now - started} s`)
		result.profile:release()
	end, 60)
end)

return nil
