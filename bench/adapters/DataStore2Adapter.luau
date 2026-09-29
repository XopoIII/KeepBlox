--!strict
--- DataStore2 (downloaded, unmodified, with its default saving method, OrderedBackups) behind the
--- simulator's `Adapter` shape, used as its docs say: `DataStore2(name, player)`, `Get(default)`, `Set`
--- on every change, and the library's own save when the player leaves or the server closes.
---
--- DataStore2 has no session lock and no autosave. A player is a fake `Player` whose leaving (its
--- `AncestryChanged`) triggers the save, exactly as in a game. `AfterSave` reports what each save
--- stored: those are the acknowledgements.
const Adapter = require("@sim/Adapter")
const Encoding = require("@fakes/Encoding")
const Rival = require("./Rival")

const TREE = Rival.tree("DataStore2")
const STORE = "Profiles"

-- The simulator's keys are "u_<n>"; DataStore2 keys by the player's UserId.
const function userIdOf(key: string): number
	return assert(tonumber(string.match(key, "%d+")), `a DataStore2 key needs a user id: {key}`)
end

--> OrderedBackups: every save is a new key `n` of data store "Profiles/<UserId>", and the ordered
--> store of the same name holds `n`; the highest is current (OrderedBackups.lua).
const FORMAT: Adapter.Format = {
	data = function(value: any): Adapter.Data?
		return if type(value) == "table" and type(value.p) == "table" then value else nil
	end,
	current = function(world: any, key: string): Adapter.Data?
		const id = `{STORE}/{userIdOf(key)}/global`
		local newest: number? = nil
		for _, value in world.ordered[id] or {} do
			newest = math.max(newest or value, value)
		end
		if newest == nil then
			return nil
		end
		const latest = world.backend:latest(id, tostring(newest))
		return if latest and type(latest.value) == "table" then latest.value else nil
	end,
}

const DataStore2Adapter: Adapter.Adapter = {
	name = "DataStore2",
	store = `{STORE}/global`,
	format = FORMAT,
	boot = function(env: any): Adapter.Library
		const DataStore2 = env.globals.require(env:mount(TREE))
		const task = env.globals.task
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const player = env.players.join(userIdOf(key))
				const store = DataStore2(STORE, player)
				const ok, loaded = pcall(function(): any
					return store:Get({ p = {} })
				end)
				if not ok then
					env.players.leave(player)
					return nil
				end
				const data = Encoding.copy(loaded)
				store:AfterSave(function(saved: any)
					hooks.acked(Encoding.copy(saved))
				end)
				local active = true
				if hooks.cancelled() then
					active = false
					env.players.leave(player)
					return nil
				end
				-- A game calls Set whenever its data changes; the simulator changes it every step.
				task.spawn(function()
					while active do
						store:Set(Encoding.copy(data))
						task.wait(1)
					end
				end)
				return {
					data = data,
					isActive = function(): boolean
						return active
					end,
					release = function()
						store:Set(Encoding.copy(data))
						active = false
						env.players.leave(player)
						hooks.ended()
					end,
				}
			end,
		}
	end,
}

return DataStore2Adapter
