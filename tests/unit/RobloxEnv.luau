--!strict
--- The simulated engine rival libraries run in (tests/sim/RobloxEnv, env/*): its scheduling rules,
--- `require` over a module tree, signals, and the data store surface they call.
const RobloxEnv = require("@sim/RobloxEnv")
const Sim = require("./Sim")
const Spec = require("../Spec")
const World = require("@fakes/World")

const function setup(): (World.World, World.Server, RobloxEnv.Env)
	const world = World.new(1)
	const server = world:server({ name = "A", players = 1 })
	return world, server, RobloxEnv.new(world, server)
end

Spec.test("RobloxEnv: coroutine.wrap threads may wait, and hand control back to the caller", function()
	const world, _, env = setup()
	const order: { string } = {}
	Sim.run(world.scheduler, "A", function()
		const wrapped = env.globals.coroutine.wrap(function()
			table.insert(order, "start")
			env.globals.task.wait(1)
			table.insert(order, "after wait")
		end)
		wrapped()
		table.insert(order, "caller")
	end)
	Spec.equal(order, { "start", "caller", "after wait" })
end)

Spec.test("RobloxEnv: an error in coroutine.wrap goes to the caller", function()
	const world, _, env = setup()
	local caught = ""
	Sim.run(world.scheduler, "A", function()
		const ok, problem = pcall(env.globals.coroutine.wrap(function()
			error("boom", 0)
		end))
		Spec.equal(ok, false)
		caught = problem
	end)
	Spec.equal(caught, "boom")
end)

Spec.test("RobloxEnv: task.cancel stops a waiting thread; task.defer returns its thread", function()
	const world, _, env = setup()
	local ran = false
	Sim.run(world.scheduler, "A", function()
		const task = env.globals.task
		const waiting = task.spawn(function()
			task.wait(5)
			ran = true
		end)
		task.cancel(waiting)
		Spec.equal(type(task.defer(function() end)), "thread")
	end)
	Spec.equal(ran, false)
end)

Spec.test("RobloxEnv: require runs a module tree once per server, each module with its own script", function()
	const world, _, env = setup()
	const tree: RobloxEnv.Node = {
		name = "Lib",
		source = "local Child = require(script.Child)\nreturn { value = Child.value + 1, name = script.Name }",
		children = {
			{
				name = "Child",
				source = "count = (count or 0) + 1\nreturn { value = 41, parent = script.Parent.Name }",
				children = {},
			},
		},
	}
	Sim.run(world.scheduler, "A", function()
		const root = env:mount(tree)
		const first = env.globals.require(root)
		Spec.equal(first.value, 42)
		Spec.equal(first.name, "Lib")
		Spec.truthy(rawequal(env.globals.require(root), first), "the same table, not a second run")
		Spec.equal(env.globals.require(root:FindFirstChild("Child")).parent, "Lib")
	end)
end)

Spec.test("RobloxEnv: a BindableEvent fires deferred; Wait resumes with the arguments", function()
	const world, _, env = setup()
	local got: any = nil
	Sim.run(world.scheduler, "A", function()
		const event = env.globals.Instance.new("BindableEvent")
		env.globals.task.spawn(function()
			got = table.pack(event.Event:Wait())
		end)
		event:Fire(1, "two")
		Spec.equal(got, nil, "not yet: deferred")
		env.globals.task.wait()
	end)
	Spec.equal(got.n, 2)
	Spec.equal({ got[1], got[2] }, { 1, "two" })
end)

Spec.test("RobloxEnv: legacy request types map onto the budgets; keys may be numbers", function()
	const world, server, env = setup()
	Sim.run(world.scheduler, "A", function()
		const service = env.globals.game:GetService("DataStoreService")
		const Enum = env.globals.Enum
		const store = service:GetDataStore("S")
		for index = 1, 5 do
			store:GetAsync(`read{index}`)
		end
		-- UpdateAsync draws on both budgets: it has what the emptier one has.
		const reads = service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
		Spec.truthy(reads < 100, `reads were spent ({reads} left)`)
		Spec.equal(service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync), reads)
		Spec.equal(service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync), 100)
		store:SetAsync(123, { ok = true })
		Spec.equal(store:GetAsync("123"), { ok = true })
		Spec.equal(env.globals.typeof(Enum.DataStoreRequestType.GetAsync), "EnumItem")
	end)
	Spec.equal(server.budget.spent.StandardWrite, 1)
end)

Spec.test("RobloxEnv: players join and leave with the engine's signals", function()
	const world, _, env = setup()
	local left: any = nil
	Sim.run(world.scheduler, "A", function()
		const player = env.players.join(7)
		Spec.equal(player.UserId, 7)
		Spec.equal(env.globals.typeof(player), "Instance")
		Spec.equal(player:IsDescendantOf(env.globals.game.Players), true)
		player.AncestryChanged:Connect(function()
			left = player.Parent
		end)
		env.players.leave(player)
		env.globals.task.wait()
		Spec.equal(#env.globals.game.Players:GetPlayers(), 0)
	end)
	Spec.equal(left, nil)
end)

return nil
