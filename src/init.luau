--!strict
--- KeepBlox: session-locked player data on DataStore, compatible with ProfileStore's records.
---
---     const KeepBlox = require(path.to.KeepBlox)
---     const store = KeepBlox.store("Profiles", { template = { coins = 0 } })
---
---     Players.PlayerAdded:Connect(function(player)
---         const result = store:load(`u_{player.UserId}`, {
---             cancel = function() return player.Parent == nil end,
---         })
---         if not result.ok then
---             player:Kick(`Your data could not be loaded ({result.reason}). Please rejoin.`)
---             return
---         end
---         const profile = result.profile
---         profile:addUserId(player.UserId)
---         profile.onEnded:connect(function(reason)
---             if reason ~= "released" then player:Kick("Your data was opened elsewhere.") end
---         end)
---         -- use profile.Data; release it when the player leaves:
---     end)
---
---     Players.PlayerRemoving:Connect(function(player)
---         const profile = store:profiles()[`u_{player.UserId}`]
---         if profile then profile:release() end
---     end)
const Config = require("@self/Config")
const Importers = require("@self/Importers")
const Migrate = require("@self/Migrate")
const Profile = require("@self/Profile")
const Receipts = require("@self/Receipts")
const Record = require("@self/Record")
const Schema = require("@self/Schema")
const Shared = require("@self/Shared")
const Store = require("@self/Store")

export type Store = Store.Store
--> What `KeepBlox.store` takes.
export type StoreOptions = Store.Options
export type SharedStore = Shared.SharedStore
--> What `KeepBlox.shared` takes.
export type SharedOptions = Shared.Options
export type Profile = Profile.Profile
--> Why a session ended: what `profile.onEnded` fires with.
export type EndReason = Profile.EndReason
--> What `store:load` takes.
export type LoadOptions = Store.LoadOptions
export type LoadResult = Store.LoadResult
--> Why a load failed: the `reason` of a `LoadResult` that is not ok.
export type LoadFailure = Store.LoadFailure
--> A purchase as `MarketplaceService.ProcessReceipt` hands it over, what `store:receipts` and
--> `KeepBlox.processReceipt` take, and the name of the decision `store:receipts` answers with.
export type Receipt = Receipts.Receipt
export type ReceiptOptions = Receipts.Options
export type ReceiptDecision = Receipts.Decision
export type Config = Config.Config
--> A store's `config`: any of the settings, the rest keep their defaults.
export type ConfigOverrides = Config.Overrides
--> One migration: a step, or `{ up, down }` for a release that can be rolled back (see Migrate).
export type Migration = Migrate.Migration

const KeepBlox = {}

--> Opens the store `name` (one DataStore). See `Store.Options`.
KeepBlox.store = Store.new

--> The protocol's default numbers.
KeepBlox.defaults = Config.DEFAULT

--> Opens the shared store `name`: documents no server owns, changed atomically by any (see Shared).
KeepBlox.shared = Shared.new

--> Builders for a store's `schema` (see Schema).
KeepBlox.schema = Schema

--> Importers for a store's `import`: moving from DocumentService, Lapis, DataKeep, DataStore2 or
--> Suphi's DataStore Module (see Importers). ProfileStore and ProfileService need none: KeepBlox reads
--> their records as they are.
KeepBlox.importers = Importers

--> Runs a store's migrations, defaults and schema check on a copy of `data` stored at version `from`,
--> exactly as a load does. For testing each migration with fixtures from before and after it.
function KeepBlox.migrate(
	options: {
		read schema: Schema.Node?,
		read version: number?,
		read migrations: { read [number]: Migrate.Migration }?,
	},
	data: any,
	from: number
): Migrate.Outcome
	const plan = Migrate.plan(options.schema, options.version, options.migrations)
	return Migrate.run(plan, Record.copy(data), from)
end

--> Runs a store's down steps on a copy of `data`, at `version`, down to version `to`: what a release
--> with `writeVersion = to` stores. For testing that each `down` undoes its `up`.
function KeepBlox.migrateDown(
	options: {
		read schema: Schema.Node?,
		read version: number?,
		read migrations: { read [number]: Migrate.Migration }?,
	},
	data: any,
	to: number
): { ok: true, data: any } | { ok: false, message: string }
	const plan = Migrate.plan(options.schema, options.version, options.migrations)
	const turned, problem = Migrate.down(plan, Record.copy(data), to)
	if problem then
		return { ok = false, message = problem }
	end
	return { ok = true, data = turned }
end

--> The callback for `MarketplaceService.ProcessReceipt`, over `store:receipts(options)`: it returns the
--> engine's `Enum.ProductPurchaseDecision`.
function KeepBlox.processReceipt(
	store: Store.Store,
	options: Receipts.Options
): (receipt: Receipts.Receipt) -> Enum.ProductPurchaseDecision
	const decide = store:receipts(options)
	return function(receipt: Receipts.Receipt): Enum.ProductPurchaseDecision
		return if decide(receipt) == "PurchaseGranted"
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

return table.freeze(KeepBlox)
