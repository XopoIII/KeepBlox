--!strict
--- No library: a game's own save code, the way the Roblox guides teach it
--- (https://create.roblox.com/docs/cloud-services/data-stores/manage-data-stores and
--- https://create.roblox.com/docs/tutorials/use-case-tutorials/data-storage/save-player-data):
--- read the player's key with GetAsync when they join (retried a few times), write it with SetAsync when
--- they leave and every 60 seconds, and save everyone on BindToClose. No session lock: nothing stops two
--- servers holding one player, which is what the comparison shows.
const Adapter = require("@sim/Adapter")

const STORE = "PlayerData"
const SAVE_EVERY = 60
const TRIES = 3

const BareAdapter: Adapter.Adapter = {
	name = "No library (GetAsync / SetAsync)",
	store = `{STORE}/global`,
	format = {
		data = function(value: any): Adapter.Data?
			return if type(value) == "table" and type(value.p) == "table" then value else nil
		end,
	},
	boot = function(env: any): Adapter.Library
		const game = env.globals.game
		const task = env.globals.task
		const store = game:GetService("DataStoreService"):GetDataStore(STORE)
		const open: { [string]: () -> () } = {}
		game:BindToClose(function()
			local pending = 0
			for _, save in open do
				pending += 1
				task.spawn(function()
					save()
					pending -= 1
				end)
			end
			while pending > 0 do
				task.wait(0.1)
			end
		end)

		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				local ok, value = false, nil
				for try = 1, TRIES do
					ok, value = pcall(store.GetAsync, store, key)
					if ok or try == TRIES then
						break
					end
					task.wait(1)
				end
				if not ok then
					return nil
				end
				const data: Adapter.Data = if type(value) == "table" and type(value.p) == "table"
					then value
					else { p = {} }
				local active = true
				const function save()
					const copy = { p = table.clone(data.p) }
					if pcall(store.SetAsync, store, key, copy) then
						hooks.acked(copy)
					end
				end
				open[key] = save
				task.spawn(function()
					while active do
						task.wait(SAVE_EVERY)
						if active then
							save()
						end
					end
				end)
				return {
					data = data,
					isActive = function(): boolean
						return active
					end,
					release = function()
						active = false
						open[key] = nil
						save()
						hooks.ended()
					end,
				}
			end,
		}
	end,
}

return BareAdapter
