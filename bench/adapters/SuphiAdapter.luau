--!strict
--- Suphi's DataStore Module (vendored unmodified in tests/reference/Suphi: it ships only as a Roblox
--- asset) behind the simulator's `Adapter` shape, used as its DevForum post says: `new(name, key)` in
--- PlayerAdded, `Open(template)` (anything but "Success" kicks), and `Destroy` on leave, which saves.
---
--- Its lock lives in MemoryStore (a sorted map per key), so the ledger's lock checks do not apply; its
--- `Saved` signal reports exactly what each save stored: those are the acknowledgements.
const Adapter = require("@sim/Adapter")
const Encoding = require("@fakes/Encoding")
const RobloxEnv = require("@sim/RobloxEnv")

const TREE = RobloxEnv.tree("tests/reference/Suphi", "SuphiDataStore")
const STORE = "Profiles"

--> The game's own value, stored as it is.
const FORMAT: Adapter.Format = {
	data = function(value: any): Adapter.Data?
		return if type(value) == "table" and type(value.p) == "table" then value else nil
	end,
}

const SuphiAdapter: Adapter.Adapter = {
	name = "Suphi",
	store = `{STORE}/global`,
	format = FORMAT,
	boot = function(env: any): Adapter.Library
		const Module = env.globals.require(env:mount(TREE))
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const dataStore = Module.new(STORE, key)
				dataStore.Saved:Connect(function(response: string, value: any)
					if response == "Saved" then
						hooks.acked(Encoding.copy(value))
					end
				end)
				dataStore.StateChanged:Connect(function(state: boolean?)
					if state ~= true then
						hooks.ended()
					end
				end)
				if dataStore:Open({ p = {} }) ~= "Success" then
					dataStore:Destroy()
					return nil
				end
				if hooks.cancelled() then
					dataStore:Destroy()
					return nil
				end
				return {
					data = dataStore.Value,
					isActive = function(): boolean
						return dataStore.State == true
					end,
					release = function()
						dataStore:Destroy()
					end,
				}
			end,
		}
	end,
}

return SuphiAdapter
