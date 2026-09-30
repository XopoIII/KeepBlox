--!strict
--- A game's use of KeepBlox's public API, type-checked under both of Luau's type solvers and never run.
---
--- Games are checked with whichever solver their project uses, and the old one drops every property
--- written with a `read` or `write` modifier: a game on it could not see `profile.onSaving`,
--- `profile.loadCount` or `store.onError` ("Key not found"). `scripts/type-check.sh` checks this file
--- with the old solver too, so a public type that only the new solver reads fails the gate.
const KeepBlox = require("@keepblox")

-- A list that mixes steps and `{ up, down }` pairs is annotated: the old solver takes a list literal's
-- element type from its first element otherwise.
const MIGRATIONS: { KeepBlox.Migration } = {
	function(data: any)
		data.coins = data.coins or 0
	end,
	{
		up = function(data: any)
			data.items = data.items or {}
		end,
		down = function(data: any)
			data.items = nil
		end,
	},
}

const store: KeepBlox.Store = KeepBlox.store("Profiles", {
	template = { coins = 0, items = {} },
	migrations = MIGRATIONS,
	writeVersion = 1,
	import = KeepBlox.importers.custom({
		name = "Old",
		fetch = function(services: any, key: string): (any, any)
			return services.dataStores:GetDataStore("Old"):GetAsync(key, false)
		end,
		read = function(value: any, _info: any, _now: number): any
			return if value == nil then { kind = "none" } else { kind = "data", data = value }
		end,
	}),
	config = { loadTimeout = 60 },
	studio = "copy",
})

const name: string = store.name
store.onError:connect(function(key: string, message: string)
	print(name, key, message)
end)

const result: KeepBlox.LoadResult = store:load("u_1", {
	cancel = function(): boolean
		return false
	end,
})
if result.ok then
	const profile: KeepBlox.Profile = result.profile
	const key: string = profile.key
	const loads: number = profile.loadCount
	const created: number = profile.createdAt
	profile:addUserId(1)
	profile.onSaving:connect(function(final: boolean, reason: string?)
		profile.Data.coins += if final then 0 else 1
		print(key, loads, created, reason)
	end)
	profile.onSaved:connect(function(stored: any)
		print(stored.coins)
	end)
	profile.onEnded:connect(function(reason: string)
		print(reason)
	end)
	const saved: boolean = profile:save()
	print(saved, profile:isActive())
	profile:release()
else
	print(result.reason)
end

const open: { [string]: KeepBlox.Profile } = store:profiles()
print(open)

const decide = KeepBlox.processReceipt(store, {
	keyFor = function(userId: number): string
		return `u_{userId}`
	end,
	products = {
		[1] = function(profile: KeepBlox.Profile, _receipt: any)
			profile.Data.coins += 100
		end,
	},
})
print(decide)

const outcome = KeepBlox.migrate({ version = 2, migrations = MIGRATIONS }, {}, 0)
const turned = KeepBlox.migrateDown({ version = 2, migrations = MIGRATIONS }, { coins = 0, items = {} }, 1)
print(turned)
print(outcome)

const shared: KeepBlox.SharedStore = KeepBlox.shared("Guilds", { template = {} })
const sharedName: string = shared.name
print(sharedName)

return nil
