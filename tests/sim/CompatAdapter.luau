--!strict
--- The same game code as ProfileStoreAdapter, line for line, with one change: the ProfileStore module
--- comes from KeepBlox's compatibility layer. Every scenario run on it proves the one-line migration.
const Adapter = require("./Adapter")
const CompatProfileStore = require("@keepblox/Compat/ProfileStore")
const RobloxEnv = require("./RobloxEnv")

const STORE = "Profiles"

const CompatAdapter: Adapter.Adapter = {
	name = "Compat",
	store = `{STORE}/global`,
	boot = function(env: RobloxEnv.Env): Adapter.Library
		const ProfileStore = CompatProfileStore.withServices(env.server.services) -- the one changed line
		const store = ProfileStore.New(STORE, { p = {} })
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const profile = store:StartSessionAsync(key, { Cancel = hooks.cancelled })
				if profile == nil then
					return nil
				end
				profile.OnAfterSave:Connect(function(saved: Adapter.Data)
					hooks.acked(saved)
				end)
				profile.OnSessionEnd:Connect(hooks.ended)
				return {
					data = profile.Data,
					isActive = function(): boolean
						return profile:IsActive()
					end,
					release = function()
						profile:EndSession()
					end,
				}
			end,
		}
	end,
}

return CompatAdapter
