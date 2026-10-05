--!strict
--- KeepBlox behind the simulator's `Adapter` shape, used the way its documentation tells a game to:
--- `load` with a `cancel` for a player who left, `onSaved` for what is stored, `onEnded` to kick, and
--- `release` on leave. It runs on the virtual server's services directly, since KeepBlox reaches the
--- engine only through the seam.
const Adapter = require("./Adapter")
const KeepBlox = require("@keepblox")
const RobloxEnv = require("./RobloxEnv")

const STORE = "Profiles"

--> An adapter with `config` overrides, for exploring the protocol's numbers.
const function with(config: KeepBlox.ConfigOverrides?): Adapter.Adapter
	return {
		name = "KeepBlox",
		store = `{STORE}/global`,
		boot = function(env: RobloxEnv.Env): Adapter.Library
			const store = KeepBlox.store(STORE, {
				template = { p = {} },
				services = env.server.services,
				config = config,
			})
			return {
				open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
					const result = store:load(key, { cancel = hooks.cancelled })
					if not result.ok then
						return nil
					end
					const profile = result.profile
					profile.onSaved:connect(function(saved: Adapter.Data)
						hooks.acked(saved)
					end)
					profile.onEnded:connect(function()
						hooks.ended()
					end)
					return {
						data = profile.Data,
						isActive = function(): boolean
							return profile:isActive()
						end,
						release = function()
							profile:release()
						end,
					}
				end,
			}
		end,
	}
end

const KeepBloxAdapter = with(nil)

return table.freeze({ default = KeepBloxAdapter, with = with })
