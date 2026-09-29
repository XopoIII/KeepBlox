--!strict
--- Lapis (downloaded, unmodified, with its Promise dependency beside it as Wally lays them out) behind
--- the simulator's `Adapter` shape, used as its docs say: `createCollection` with `freezeData = false`
--- so the game changes the data in place, `load(key)`, and `close()` on leave.
---
--- Lapis tells the game nothing when another server takes the lock: its autosave only warns. So a
--- session stays active until the game closes it, and the stale-owner column shows how long that is.
--- It has no signal carrying the saved data either, so saves are acknowledged at the service boundary
--- (see Rival).
const Adapter = require("@sim/Adapter")
const Rival = require("./Rival")

const PACKAGES: any = { name = "Packages", children = { Rival.tree("Lapis"), Rival.tree("Promise") } }
const STORE = "Profiles"

--> `{migrationVersion, lastCompatibleVersion, lockId, data}` (Collection.luau), the lock a GUID.
const FORMAT: Adapter.Format = {
	data = function(value: any): Adapter.Data?
		return if type(value) == "table" and type(value.data) == "table" then value.data else nil
	end,
}

const LapisAdapter: Adapter.Adapter = {
	name = "Lapis",
	store = `{STORE}/global`,
	format = FORMAT,
	boot = function(env: any): Adapter.Library
		const packages = env:mount(PACKAGES)
		const Lapis = env.globals.require(packages.Lapis)
		const collection = Lapis.createCollection(STORE, { defaultData = { p = {} }, freezeData = false })
		const sessions: { [string]: Rival.Live } = {}
		Rival.ackWrites(env, `{STORE}/global`, FORMAT, sessions)
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const ok, document = collection:load(key):await()
				if not ok then
					return nil
				end
				if hooks.cancelled() then
					document:close():await()
					return nil
				end
				local landed = false
				sessions[key] = {
					hooks = hooks,
					live = function(): boolean
						return not landed
					end,
				}
				return {
					data = document:read(),
					isActive = function(): boolean
						return not document.closed
					end,
					release = function()
						document:close():await()
						landed = true
						hooks.ended()
					end,
				}
			end,
		}
	end,
}

return LapisAdapter
