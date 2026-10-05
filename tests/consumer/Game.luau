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
	const lastSaved: number = profile.lastSavedAt
	profile:addUserId(1)
	profile.onSaving:connect(function(final: boolean, reason: string?)
		profile.Data.coins += if final then 0 else 1
		print(key, loads, created, lastSaved, reason)
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

-- The documented shape: leave early on a failure, and the profile is there after it.
const function early(key: string): KeepBlox.Profile?
	const loaded = store:load(key)
	if not loaded.ok then
		const why: KeepBlox.LoadFailure = loaded.reason
		print(`could not load ({loaded.reason})`, why)
		return nil
	end
	const profile = loaded.profile
	return profile
end
-- The same with the result annotated, and with every option type named.
const function annotated(key: string, options: KeepBlox.LoadOptions): KeepBlox.Profile?
	const loaded: KeepBlox.LoadResult = store:load(key, options)
	if not loaded.ok then
		warn(`could not load ({loaded.reason})`)
		return nil
	end
	loaded.profile.onEnded:connect(function(reason: KeepBlox.EndReason)
		print(reason)
	end)
	return loaded.profile
end
print(early, annotated)

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

-- The options built apart from the call, and the callback set where the engine reads it.
const RECEIPTS: KeepBlox.ReceiptOptions = {
	keyFor = function(userId: number): string
		return `u_{userId}`
	end,
	products = {
		[2] = function(profile: KeepBlox.Profile, receipt: KeepBlox.Receipt)
			profile.Data.coins += receipt.ProductId
		end,
	},
	history = 50,
}
game:GetService("MarketplaceService").ProcessReceipt = KeepBlox.processReceipt(store, RECEIPTS)
const named: (KeepBlox.Receipt) -> KeepBlox.ReceiptDecision = store:receipts(RECEIPTS)
const granted: Enum.ProductPurchaseDecision =
	KeepBlox.processReceipt(store, RECEIPTS)({ PlayerId = 1, PurchaseId = "p", ProductId = 2 })
print(named, granted)

-- A store's options built apart from the call.
const SETTINGS: KeepBlox.ConfigOverrides = { loadTimeout = 60, renew = 120 }
const OPTIONS: KeepBlox.StoreOptions = { template = { coins = 0 }, config = SETTINGS, studio = "memory" }
print(KeepBlox.store("Other", OPTIONS))

const outcome = KeepBlox.migrate({ version = 2, migrations = MIGRATIONS }, {}, 0)
const turned = KeepBlox.migrateDown({ version = 2, migrations = MIGRATIONS }, { coins = 0, items = {} }, 1)
print(turned)
print(outcome)

const SHARED: KeepBlox.SharedOptions = { template = {}, config = { callTimeout = 10 } }
const shared: KeepBlox.SharedStore = KeepBlox.shared("Guilds", SHARED)
const sharedName: string = shared.name
print(sharedName)

-- A game that types its data names the shape once, on the store; every profile of it carries the shape.
type PlayerData = { coins: number, items: { string } }
const typed: KeepBlox.Store<PlayerData> = KeepBlox.store("Typed", { template = { coins = 0, items = {} } })
const typedResult: KeepBlox.LoadResult<PlayerData> = typed:load("u_1")
if typedResult.ok then
	const typedProfile: KeepBlox.Profile<PlayerData> = typedResult.profile
	const coins: number = typedProfile.Data.coins
	const first: string? = typedProfile.Data.items[1]
	const stored: number = typedProfile.LastSavedData.coins
	typedProfile.Data.coins += 1
	typedProfile.onSaved:connect(function(saved: PlayerData)
		print(saved.coins)
	end)
	-- A typed profile goes wherever a plain one is taken.
	const plain: KeepBlox.Profile = typedProfile
	print(coins, first, stored, plain)
end
-- The result not annotated, the documented early return, and the open profiles: all typed by the store.
const function typedCoins(key: string): number?
	const loaded = typed:load(key)
	if not loaded.ok then
		return nil
	end
	const coins: number = loaded.profile.Data.coins
	return coins
end
const typedOpen: { [string]: KeepBlox.Profile<PlayerData> } = typed:profiles()
typed:edit("u_1", function(data: PlayerData)
	data.coins += 1
end)
typed:trade("u_1", "u_2", function(a: PlayerData, b: PlayerData)
	a.coins, b.coins = b.coins, a.coins
end)
-- A purchase handler may name the shape too.
const TYPED_RECEIPTS: KeepBlox.ReceiptOptions = {
	keyFor = function(userId: number): string
		return `u_{userId}`
	end,
	products = {
		[3] = function(profile: KeepBlox.Profile<PlayerData>, _receipt: KeepBlox.Receipt)
			profile.Data.coins += 10
		end,
	},
}
print(typed:receipts(TYPED_RECEIPTS))
-- A typed store goes wherever a plain one is taken.
const plainStore: KeepBlox.Store = typed
print(typedCoins, typedOpen, plainStore, KeepBlox.processReceipt(typed, RECEIPTS))

return nil
