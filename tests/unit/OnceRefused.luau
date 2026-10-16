--!strict
--- A change the game was told did not land never lands later (issue 41, src/Once.luau). A shared
--- update's first try may wait past the call's deadline and run after a retry already answered: the
--- answer the game got must stay true when that late try runs on what is stored by then.
const KeepBlox = require("@keepblox")
const Messages = require("@keepblox/Messages")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function bank(world: World.World): number
	return (world.backend:latest("Guilds/global", "g_1") :: any).value.Data.bank
end

const function spend(data: any)
	if data.bank < 100 then
		error("too poor", 0)
	end
	data.bank -= 100
end

const function add(data: any)
	data.bank += 100
end

Spec.test("OnceRefused: an update refused by its retry stays refused when its first try runs late", function()
	const world = World.new(12)
	const a = KeepBlox.shared("Guilds", { template = { bank = 50 }, services = world:server({ name = "A" }).services })
	const b = KeepBlox.shared("Guilds", { template = { bank = 50 }, services = world:server({ name = "B" }).services })
	Sim.run(world.scheduler, "B", function()
		Spec.equal(b:update("g_1", function() end), { ok = true, data = { bank = 50 } })
	end, 10)
	-- A's first try waits 30 s, past its 20 s deadline, then runs. Its retry, at about 21 s, finds 50 and
	-- is refused. B adds 100 at about 22 s, so the late try would find 150.
	world.faults:add({ op = "UpdateAsync", key = "g_1", server = "A", delay = 30, times = 1 })
	local result: any = nil
	world.scheduler:spawn(function()
		world.scheduler:wait(22)
		assert(b:update("g_1", add).ok, "B added")
	end, "B")
	Sim.run(world.scheduler, "A", function()
		result = a:update("g_1", spend)
	end, 200)
	Spec.equal(result, { ok = false, reason = "error", message = "too poor" })
	Spec.equal(bank(world), 150)
end)

Spec.test("OnceRefused: an update refused for its data stays refused when its first try runs late", function()
	const S = KeepBlox.schema
	const schema = S.record({ bank = S.number({ default = 50, min = 0 }) })
	const world = World.new(13)
	const a = KeepBlox.shared("Guilds", { schema = schema, services = world:server({ name = "A" }).services })
	const b = KeepBlox.shared("Guilds", { schema = schema, services = world:server({ name = "B" }).services })
	Sim.run(world.scheduler, "B", function()
		Spec.equal(b:update("g_1", function() end), { ok = true, data = { bank = 50 } })
	end, 10)
	world.faults:add({ op = "UpdateAsync", key = "g_1", server = "A", delay = 30, times = 1 })
	local result: any = nil
	world.scheduler:spawn(function()
		world.scheduler:wait(22)
		assert(b:update("g_1", add).ok, "B added")
	end, "B")
	Sim.run(world.scheduler, "A", function()
		result = a:update("g_1", function(data: any)
			data.bank -= 100
		end)
	end, 200)
	Spec.equal(result.ok, false)
	Spec.equal(result.reason, "refused")
	Spec.equal(bank(world), 150)
end)

Spec.test(
	"OnceRefused: a message refused by its retry for a full queue stays out when its first try runs late",
	function()
		const world = World.new(14)
		const store =
			KeepBlox.store("Profiles", { template = { gifts = 0 }, services = world:server({ name = "A" }).services })
		const function write(change: (record: any) -> ())
			const record = (world.backend:latest("Profiles/global", "u_1") :: any).value
			change(record)
			world.backend:write("Profiles/global", "u_1", record, {}, {}, world.scheduler.now * 1000, "B")
		end
		Sim.run(world.scheduler, "A", function()
			Spec.equal(store:message("u_1", { gift = 0 }), { ok = true })
		end, 10)
		write(function(record: any)
			for index = 2, Messages.LIMIT do
				table.insert(record.GlobalUpdates[2], { index, { gift = 0 } })
			end
			record.GlobalUpdates[1] = Messages.LIMIT
		end)
		-- A's first try waits 30 s and runs; its retry, at about 21 s, finds the queue full. The owner takes
		-- every message at about 22 s, so the late try would find room.
		world.faults:add({ op = "UpdateAsync", key = "u_1", server = "A", delay = 30, times = 1 })
		local result: any = nil
		world.scheduler:spawn(function()
			world.scheduler:wait(22)
			write(function(record: any)
				record.GlobalUpdates[2] = {}
			end)
		end, "B")
		Sim.run(world.scheduler, "A", function()
			result = store:message("u_1", { gift = 1 })
		end, 200)
		Spec.equal(result, { ok = false, reason = "full" })
		Spec.equal((world.backend:latest("Profiles/global", "u_1") :: any).value.GlobalUpdates[2], {})
	end
)

return nil
