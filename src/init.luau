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
const Profile = require("@self/Profile")
const Store = require("@self/Store")

export type Store = Store.Store
export type Profile = Profile.Profile
export type LoadResult = Store.LoadResult
export type Config = Config.Config

const KeepBlox = {}

--> Opens the store `name` (one DataStore). See `Store.Options`.
KeepBlox.store = Store.new

--> The protocol's default numbers.
KeepBlox.defaults = Config.DEFAULT

--> The callback for `MarketplaceService.ProcessReceipt`, over `store:receipts(options)`: it returns the
--> engine's `Enum.ProductPurchaseDecision`.
function KeepBlox.processReceipt(store: Store.Store, options: any): (receipt: any) -> any
	const decide = store:receipts(options)
	return function(receipt: any): any
		return (Enum :: any).ProductPurchaseDecision[decide(receipt)]
	end
end

return table.freeze(KeepBlox)
