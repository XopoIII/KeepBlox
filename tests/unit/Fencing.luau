--!strict
--- Hand-over requests are fenced by the session they were made to: a request that outlives its session
--- never ends a later one. The MessagingService request carries the owner's load count; the MemoryStore
--- one must too (a generation, as in DHSched, arXiv 2609.26363: fencing by server alone is not enough).
const KeepBlox = require("@keepblox")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const TEMPLATE = { coins = 0 }

Spec.test("Fencing: a hand-over request made to an old session never ends the owner's next one", function()
	-- The request stays in the owner's entry until its next beat; the offsets sweep one beat (4 s).
	for step = 0, 7 do
		const world = World.new(step + 1)
		const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
		const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
		local reason = "still open"
		Sim.run(world.scheduler, "A", function()
			const first = a:load("u_1")
			assert(first.ok, "A loaded")
		end, 20 + step / 2)
		-- The player hops to B, which asks A (by message and in A's entry) and gets the key, then hops
		-- straight back to A.
		Sim.run(world.scheduler, "B", function()
			const there = b:load("u_1")
			assert(there.ok, `B loaded ({(there :: any).reason})`)
			there.profile:release()
			const back = a:load("u_1")
			assert(back.ok, `A loaded again ({(back :: any).reason})`)
			back.profile.onEnded:connect(function(why: string)
				reason = why
			end)
			world.scheduler:wait(30)
			if back.profile:isActive() then
				back.profile:release()
			end
		end, world.scheduler.now + 60)
		Spec.equal(reason, "released", `offset {step / 2} s: the new session ended as "{reason}"`)
	end
end)

Spec.test("Fencing: a claim that landed unanswered and was then given up leaves the key free", function()
	-- A claim whose answer is lost may still have landed (PaxosLease Revisited, arXiv 2609.14640: an
	-- abandoned attempt must not leave a phantom owner). Here it lands, the player leaves at once, and
	-- the load gives up; the live server must not keep the key it never learnt it had.
	for _, ending in { "cancel", "timeout" } do
		const world = World.new(4)
		const a = KeepBlox.store("Profiles", {
			template = TEMPLATE,
			services = world:server({ name = "A" }).services,
			config = { loadTimeout = 10, callTimeout = 5 },
		})
		const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
		local gone = false
		world.backend:observe(function(event)
			if event.writer == "A" and event.key == "u_1" and not gone then
				gone = true
				world.faults:add({
					op = "UpdateAsync",
					server = "A",
					key = "u_1",
					error = if ending == "cancel" then "502: API Services rejected request" else nil,
					hang = if ending == "timeout" then true else nil,
					times = if ending == "cancel" then 1 else nil,
					after = true,
				})
			end
		end)
		local first: any = nil
		Sim.run(world.scheduler, "A", function()
			first = a:load("u_1", {
				cancel = function(): boolean
					return ending == "cancel" and gone
				end,
			})
		end, 30)
		Spec.equal(first, { ok = false, reason = if ending == "cancel" then "cancelled" else "timeout" }, ending)
		world.faults:clear()
		local took = math.huge
		Sim.run(world.scheduler, "B", function()
			const started = world.scheduler.now
			const there = b:load("u_1")
			assert(there.ok, `{ending}: B loaded ({(there :: any).reason})`)
			took = world.scheduler.now - started
			there.profile:release()
		end, world.scheduler.now + 200)
		Spec.truthy(took < 15, `{ending}: B took {took} s`)
	end
end)

Spec.test("Fencing: a key removed and claimed afresh elsewhere is never written by its old session", function()
	-- The load count starts over on a removed key, so it alone cannot tell the sessions apart: the
	-- server must match too (guarantee 2).
	const world = World.new(6)
	const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
	const b = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "B" }).services })
	const eraser = world:server({ name = "C" }).services.dataStores:GetDataStore("Profiles")
	local reason = "still open"
	Sim.run(world.scheduler, "A", function()
		const old = a:load("u_1")
		assert(old.ok, "A loaded")
		old.profile.onEnded:connect(function(why: string)
			reason = why
		end)
		eraser:RemoveAsync("u_1")
		const fresh = b:load("u_1")
		assert(fresh.ok, `B loaded ({(fresh :: any).reason})`)
		fresh.profile.Data.coins = 3
		fresh.profile:save()
		old.profile.Data.coins = 50
		old.profile:save()
	end, 30)
	const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
	Spec.equal(record.MetaData.SessionLoadCount, 1, "the count started over")
	Spec.equal(record.Data.coins, 3)
	Spec.equal(reason, "lost")
end)

-- Writes a request straight into server A's entry, as a newcomer would.
const function request(world: World.World, value: any)
	const entry = world.memory.maps["sorted:KB_servers"]["job-A"]
	entry.value.r = { ["Profiles/u_1"] = value }
end

Spec.test("Fencing: a request for the owner's current session, or one naming none, is handed over", function()
	for _, case in { "current", "legacy", "stale" } do
		const world = World.new(3)
		const a = KeepBlox.store("Profiles", { template = TEMPLATE, services = world:server({ name = "A" }).services })
		local reason = "still open"
		Sim.run(world.scheduler, "A", function()
			const result = a:load("u_1")
			assert(result.ok, "A loaded")
			result.profile.onEnded:connect(function(why: string)
				reason = why
			end)
			const loadCount = (world.backend:latest("Profiles/global", "u_1") :: any).value.MetaData.SessionLoadCount
			-- A bare GUID is what an older KeepBlox writes: it names no session, so it is still honoured.
			request(
				world,
				if case == "current"
					then { g = "guid-B", c = loadCount }
					elseif case == "legacy" then "guid-B"
					else { g = "guid-B", c = loadCount - 1 }
			)
			world.scheduler:wait(10)
		end, 30)
		Spec.equal(reason, if case == "stale" then "still open" else "handedOver", case)
	end
end)

return nil
