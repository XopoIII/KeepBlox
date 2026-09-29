--!strict
--- Developer product purchases, granted once and never lost (guarantee 9).
---
---     MarketplaceService.ProcessReceipt = KeepBlox.processReceipt(store, {
---         keyFor = function(userId) return `u_{userId}` end,
---         products = {
---             [12345] = function(profile, receipt) profile.Data.coins += 100 end,
---         },
---     })
---
--- The product's grant changes the profile's data, and the receipt's id joins the list in
--- `MetaData.KeepBlox.receipts`. Both are taken in the same snapshot and stored by the same write.
--- Only once a save holding the id has succeeded is the purchase reported granted. Until then Roblox
--- keeps asking, and a repeat call waits for that save instead of granting again. If the session ends
--- before the save lands, the grant is lost together with the id, and the next session grants it
--- anew: the player gets the product exactly once.
const Profile = require("./Profile")
const Session = require("./Session")

export type Decision = "PurchaseGranted" | "NotProcessedYet"

export type Receipt = { PlayerId: number, PurchaseId: string, ProductId: number, [string]: any }

export type Options = {
	--> The profile key of a player.
	keyFor: (userId: number) -> string,
	--> What each product gives: change `profile.Data`, and do not yield.
	products: { [number]: (profile: Profile.Profile, receipt: Receipt) -> () },
	--> How many receipt ids a profile remembers; Roblox never retries a very old purchase. Default 100.
	history: number?,
}

export type Internals = {
	context: () -> Session.Context,
	sessions: { [string]: Session.Session },
}

const DEFAULT_HISTORY = 100

const Receipts = {}

--> A ProcessReceipt callback that answers with a decision's name.
function Receipts.handler(internals: Internals, options: Options): (receipt: Receipt) -> Decision
	assert(type(options.keyFor) == "function", "KeepBlox: receipts need keyFor(userId)")
	assert(type(options.products) == "table", "KeepBlox: receipts need a products table")
	const history = options.history or DEFAULT_HISTORY

	return function(receipt: Receipt): Decision
		const session = internals.sessions[options.keyFor(receipt.PlayerId)]
		if session == nil or not session.active or session.releasing then
			return "NotProcessedYet"
		end
		const id = receipt.PurchaseId
		if session.storedReceipts[id] then
			return "PurchaseGranted"
		end
		if not table.find(session.receipts, id) then
			const grant = options.products[receipt.ProductId]
			if grant == nil then
				internals.context().report(session.key, `no grant for product {receipt.ProductId}`)
				return "NotProcessedYet"
			end
			const ok, problem = pcall(grant, session.profile, receipt)
			if not ok then
				internals.context().report(session.key, `the grant for product {receipt.ProductId} failed: {problem}`)
				return "NotProcessedYet"
			end
			-- The id joins the list right after the grant, with no yield between: one snapshot holds both.
			table.insert(session.receipts, id)
			while #session.receipts > history do
				const oldest = table.remove(session.receipts, 1)
				session.storedReceipts[oldest :: string] = nil
			end
		end
		Session.save(session.context, session)
		return if session.storedReceipts[id] then "PurchaseGranted" else "NotProcessedYet"
	end
end

return Receipts
