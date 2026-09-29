--!strict
--- The vendored ProfileStore behind the simulator's `Adapter` shape. It is used exactly as its
--- documentation says a game should use it: `StartSessionAsync` with a `Cancel` for a player who left,
--- `OnAfterSave` for what is stored, `OnSessionEnd` to kick, and `EndSession` on leave.
const Adapter = require("./Adapter")
const RobloxEnv = require("./RobloxEnv")

const SOURCE = RobloxEnv.read("tests/reference/ProfileStore.luau")
const STORE = "Profiles"

const ProfileStoreAdapter: Adapter.Adapter = {
	name = "ProfileStore",
	store = `{STORE}/global`,
	boot = function(env: RobloxEnv.Env): Adapter.Library
		const ProfileStore = env:load(SOURCE, "ProfileStore")
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

return ProfileStoreAdapter
