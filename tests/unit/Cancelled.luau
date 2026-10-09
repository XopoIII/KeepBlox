--!strict
--- A game may cancel a thread that is inside `profile:save()` (`task.cancel`, `coroutine.close`):
--- queued behind another write, or with its own write in flight. That ends the thread and nothing
--- else. The write still lands, and every later manual save, renewal and the release go on
--- (src/Serial.luau, src/Session.luau; issue 29).
const CancelRig = require("./CancelRig")
const Sim = require("./Sim")
const Spec = require("../Spec")

const rig = CancelRig.new
const stored = CancelRig.stored
const RENEW = CancelRig.RENEW

type Rig = CancelRig.Rig

-- What must go on working after the cancel: a manual save, a renewal and the release, each storing
-- exactly what the game held then. Returns the writes these three made.
const function goesOn(rigged: Rig, profile: any): number
	const world = rigged.world
	const before = #rigged.log
	profile.Data.coins = 8
	Spec.equal(profile:save(), true, "a later manual save answers")
	Spec.equal(stored(world).Data.coins, 8)
	profile.Data.coins = 9
	world.scheduler:wait(RENEW * 2 + 2) -- a renewal is due within this, however the key's offset falls
	Spec.equal(stored(world).Data.coins, 9, "the renewal stored the change")
	profile.Data.coins = 10
	profile:release()
	Spec.equal(stored(world).Data.coins, 10, "the release stored the last change")
	Spec.equal(stored(world).MetaData.ActiveSession, nil, "the key is free")
	Spec.equal(profile:isActive(), false)
	return #rigged.log - before
end

Spec.test("Cancelled: a manual save cancelled with its write in flight still lands, and the lane goes on", function()
	const rigged = rig()
	const world = rigged.world
	local later = 0
	Sim.run(world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const loaded = #rigged.log
		profile.Data.coins = 7
		const holder = rigged.save(profile, "holder")
		Spec.equal(#rigged.log, loaded, "the write is in flight, not landed")
		world.scheduler:cancel(holder)
		world.scheduler:wait(5)
		-- The write the cancelled thread asked for landed, once.
		Spec.equal(stored(world).Data.coins, 7)
		Spec.equal(#rigged.log, loaded + 1)
		later = goesOn(rigged, profile)
	end, 300)
	Spec.equal(rigged.answers, {}, "the cancelled caller never went on")
	Spec.equal(rigged.errors, {})
	-- One manual save, the renewals of 42 seconds (one or two, by the key's offset), one release.
	assert(later == 3 or later == 4, `the three later writes cost {later} requests`)
end)

Spec.test("Cancelled: a queued manual save cancelled does not hang the manual saves after it", function()
	const rigged = rig()
	const world = rigged.world
	Sim.run(world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const loaded = #rigged.log
		profile.Data.coins = 7
		-- The first holds the lane inside its write; the second owns the save that waits behind it; the
		-- third joins the second's save.
		rigged.save(profile, "holder")
		const queued = rigged.save(profile, "queued, cancelled")
		rigged.save(profile, "joined")
		world.scheduler:cancel(queued)
		world.scheduler:wait(5)
		-- The save the cancelled thread owned still ran, for the one who joined it.
		Spec.equal(rigged.answers, { holder = true, joined = true })
		Spec.equal(#rigged.log, loaded + 2)
		Spec.equal(stored(world).Data.coins, 7)
		goesOn(rigged, profile)
	end, 300)
	Spec.equal(rigged.answers, { holder = true, joined = true })
	Spec.equal(rigged.errors, {})
end)

Spec.test("Cancelled: callers nobody cancels get their answers, for the same requests as before", function()
	const rigged = rig()
	const world = rigged.world
	Sim.run(world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const loaded = #rigged.log
		const spent = rigged.server.budget.spent.StandardWrite
		local saving = 0
		const finals: { string } = {}
		profile.onSaving:connect(function(final: boolean, reason: string?)
			saving += 1
			if final then
				table.insert(finals, `{reason} with {profile.Data.coins}`)
			end
		end)
		profile.Data.coins = 7
		rigged.save(profile, "holder")
		Spec.equal(saving, 1, "the first save starts in the caller's own turn, before it yields")
		rigged.save(profile, "queued")
		rigged.save(profile, "joined")
		Spec.equal(saving, 1, "the queued save has not started")
		profile.Data.coins = 8 -- after the holder's snapshot, before the queued save's
		world.scheduler:wait(5)
		Spec.equal(rigged.answers, { holder = true, queued = true, joined = true })
		-- Three callers, two writes: the holder's, and the one the other two share.
		Spec.equal(#rigged.log, loaded + 2)
		Spec.equal(stored(world).Data.coins, 8)
		Spec.equal(rigged.log[loaded + 1], { coins = 7, held = true }, "the earlier save landed first")
		Spec.equal(rigged.log[loaded + 2], { coins = 8, held = true })
		Spec.equal(rigged.server.budget.spent.StandardWrite, spent + 2, "one request a write")
		profile:release()
		Spec.equal(rigged.log[loaded + 3], { coins = 8, held = false })
		Spec.equal(#rigged.log, loaded + 3)
		Spec.equal(rigged.server.budget.spent.StandardWrite, spent + 3)
		Spec.equal(finals, { "released with 8" })
	end, 300)
	Spec.equal(rigged.errors, {})
end)

Spec.test("Cancelled: shutdown waits for a write whose caller was cancelled, and for the release after it", function()
	const rigged = rig()
	const world = rigged.world
	Sim.run(world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		const loaded = #rigged.log
		profile.Data.coins = 7
		const holder = rigged.save(profile, "holder")
		world.scheduler:cancel(holder)
		profile.Data.coins = 8
		-- The game closes with that write still in flight.
		Spec.equal(#rigged.log, loaded)
		Spec.equal(#rigged.server.closing, 1)
		const started = world.scheduler.now
		rigged.server.closing[1]()
		Spec.equal(world.scheduler.now > started, true, "the close waited")
		-- Both had landed, in order, when the close returned: the write in flight, then the final save.
		Spec.equal(#rigged.log, loaded + 2)
		Spec.equal(rigged.log[loaded + 1], { coins = 7, held = true })
		Spec.equal(rigged.log[loaded + 2], { coins = 8, held = false })
		Spec.equal(profile:isActive(), false)
	end, 300)
	Spec.equal(rigged.answers, {})
	Spec.equal(rigged.errors, {})
end)

return nil
