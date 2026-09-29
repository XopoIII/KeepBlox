--!strict
--- ProfileService (downloaded, unmodified) behind the simulator's `Adapter` shape, used as its README
--- says a game should: `LoadProfileAsync(key, "ForceLoad")`, release a profile whose player already
--- left, `ListenToRelease` to kick, and `Release` on leave. It has no signal carrying the saved data, so
--- saves are acknowledged at the service boundary (see Rival).
const Adapter = require("@sim/Adapter")
const Rival = require("./Rival")

const TREE = Rival.tree("ProfileService")
const STORE = "Profiles"

const ProfileServiceAdapter: Adapter.Adapter = {
	name = "ProfileService",
	store = `{STORE}/global`,
	boot = function(env: any): Adapter.Library
		const ProfileService = env.globals.require(env:mount(TREE))
		const store = ProfileService.GetProfileStore(STORE, { p = {} })
		const sessions: { [string]: Rival.Live } = {}
		Rival.ackWrites(env, `{STORE}/global`, Adapter.PROFILE_STORE, sessions)
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const profile = store:LoadProfileAsync(key, "ForceLoad")
				if profile == nil then
					return nil
				end
				if hooks.cancelled() then
					profile:Release()
					return nil
				end
				-- Release listeners fire before the final write; the session's writes land until hop-ready.
				local landed = false
				sessions[key] = {
					hooks = hooks,
					live = function(): boolean
						return not landed
					end,
				}
				profile:ListenToRelease(hooks.ended)
				profile:ListenToHopReady(function()
					landed = true
				end)
				return {
					data = profile.Data,
					isActive = function(): boolean
						return profile:IsActive()
					end,
					release = function()
						profile:Release()
					end,
				}
			end,
		}
	end,
}

return ProfileServiceAdapter
