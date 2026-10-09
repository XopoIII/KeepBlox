--!strict
--- A write that fails or throws, with its caller there to hear it and with its caller cancelled: the
--- answer reaches whoever still waits, and the store is told when nobody does (issue 29).
const CancelRig = require("./CancelRig")
const Sim = require("./Sim")
const Spec = require("../Spec")

const rig = CancelRig.new

Spec.test(
	"Cancelled errors: a write that fails still fails its caller, and is still reported with none left",
	function()
		const rigged = rig()
		const world = rigged.world
		Sim.run(world.scheduler, "A", function()
			const result = rigged.store:load("u_1")
			assert(result.ok, "loaded")
			const profile = result.profile
			profile.Data.coins = 5
			world.faults:add({
				op = "UpdateAsync",
				key = "u_1",
				error = "502: API Services rejected request",
				times = 1,
			})
			Spec.equal(profile:save(), false)
			Spec.equal(rigged.errors, { "u_1: save failed: 502: API Services rejected request" })
			-- The same failure behind a write in flight: the caller that owns the save and the one that
			-- joined it both hear `false`.
			rigged.save(profile, "holder")
			world.faults:add({
				op = "UpdateAsync",
				key = "u_1",
				error = "502: API Services rejected request",
				times = 1,
			})
			profile.Data.coins = 6
			rigged.save(profile, "queued")
			rigged.save(profile, "joined")
			world.scheduler:wait(5)
			Spec.equal(rigged.answers, { holder = true, queued = false, joined = false })
			Spec.equal(#rigged.errors, 2)
			table.clear(rigged.errors)
			table.clear(rigged.answers)
			profile.Data.coins = 7
			-- A request lost in flight, and its caller cancelled meanwhile: the deadline still ends the
			-- write, nobody hears `false`, and the store is still told.
			world.faults:add({ op = "UpdateAsync", key = "u_1", hang = true, times = 1 })
			const started = world.scheduler.now
			const loaded = #rigged.log
			const holder = rigged.save(profile, "holder, cancelled")
			world.scheduler:cancel(holder)
			-- A save behind it waits for the deadline (callTimeout, 20 s), then lands.
			Spec.equal(profile:save(), true)
			Spec.equal(world.scheduler.now - started >= 20, true, "it waited for the lost write's deadline")
			Spec.equal(world.scheduler.now - started < 22, true, "and no longer")
			Spec.equal(rigged.errors, { "u_1: save failed: timeout" })
			Spec.equal(#rigged.log, loaded + 1)
			Spec.equal(rigged.log[loaded + 1], { coins = 7, held = true })
			profile:release()
		end, 300)
		Spec.equal(rigged.answers, {})
	end
)

Spec.test("Cancelled errors: a write that throws reaches its caller, those who joined, and the store", function()
	-- A compressing store whose codec can be broken: the one step of a write that throws.
	const rigged = rig({ template = { coins = 0, text = string.rep("a", 500) }, compress = { above = 100 } })
	const world = rigged.world
	local caught: any = nil
	local joined: any = nil
	Sim.run(world.scheduler, "A", function()
		const result = rigged.store:load("u_1")
		assert(result.ok, "loaded")
		const profile = result.profile
		-- Holds the lane with a write in flight; what queues behind it meets the broken codec.
		const function hold(coins: number)
			profile.Data.coins = coins
			rigged.save(profile, `holder {coins}`)
			profile.Data.coins = coins + 1
			rigged.codec.broken = true
		end
		hold(1)
		const loaded = #rigged.log
		-- The caller that owns the save hears the error itself; the one that joined it hears `false`.
		world.scheduler:resume(function()
			const _, problem = pcall(profile.save, profile)
			caught = problem
		end)
		world.scheduler:resume(function()
			joined = profile:save()
		end)
		world.scheduler:wait(5)
		Spec.equal(caught, "the codec is down")
		Spec.equal(joined, false)
		Spec.equal(rigged.errors, {})
		Spec.equal(#rigged.log, loaded + 1)
		-- The same with the owner cancelled while its save waits its turn: the store is told.
		rigged.codec.broken = false
		hold(3)
		world.scheduler:cancel(rigged.save(profile, "owner, cancelled"))
		world.scheduler:wait(5)
		Spec.equal(rigged.errors, { "u_1: a write failed after its caller was cancelled: the codec is down" })
		Spec.equal(#rigged.log, loaded + 2)
		Spec.equal(rigged.log[loaded + 2], { coins = 3, held = true })
		-- And the lane goes on once the codec is back.
		rigged.codec.broken = false
		Spec.equal(profile:save(), true)
		Spec.equal(rigged.log[loaded + 3], { coins = 4, held = true })
		profile:release()
	end, 300)
	Spec.equal(rigged.answers, { ["holder 1"] = true, ["holder 3"] = true })
end)

return nil
