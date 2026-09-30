--!strict
--- What the fakes model because the live check measured it (tests/fakes: Encoding, Backend,
--- DataStore, Messaging, Ordered, Budget), checked again on the real services. A failure here means
--- Roblox changed, and the fake is fixed first.
const Env = require("./Env")
const DataStoreService = game:GetService("DataStoreService")
const MessagingService = game:GetService("MessagingService")

const Conformance = {}

const function uncached(): DataStoreGetOptions
	const options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	return options
end

-- The error `fn` throws, or nil.
const function thrown(fn: () -> ()): string?
	const ok, message = pcall(fn)
	return if ok then nil else tostring(message)
end

const function has(text: string?, fragment: string): boolean
	return text ~= nil and string.find(text, fragment, 1, true) ~= nil
end

function Conformance.encoding()
	const store = DataStoreService:GetDataStore(`{Env.store}_enc`)
	const function roundTrip(value: any): any
		store:SetAsync("k", { v = value })
		return (store:GetAsync("k", uncached()) :: any).v
	end
	Env.check(
		"encoding: SetAsync(nil) fails",
		has(
			thrown(function()
				store:SetAsync("nil", nil)
			end),
			"Argument 2 missing or nil"
		)
	)
	const nan = roundTrip(0 / 0)
	Env.check("encoding: NaN reads back NaN", nan ~= nan)
	Env.check("encoding: infinity reads back", roundTrip(math.huge) == math.huge)
	const mixed: { [any]: any } = { 1, 2 }
	mixed.x = 3
	Env.check("encoding: {1, 2, x = 3} keeps its array part", Env.encode(roundTrip(mixed)) == "[1,2]")
	Env.check("encoding: {[1] = 1, [3] = 3} keeps [1]", Env.encode(roundTrip({ [1] = 1, [3] = 3 })) == "[1]")
	Env.check('encoding: a key 2.5 becomes "2"', roundTrip({ [2.5] = 1 })["2"] == 1)
	Env.check(
		"encoding: a boolean key fails",
		has(
			thrown(function()
				roundTrip({ [true] = 1 })
			end),
			"Invalid table key type used"
		)
	)
	for _, number in { 0.1, 1 / 3, 2 ^ 53 + 2, 1e300, 5e-324 } do
		Env.check(`encoding: {string.format("%.17g", number)} reads back exactly`, roundTrip(number) == number)
	end
end

const function listed(store: DataStore, key: string): { DataStoreObjectVersionInfo }
	return store:ListVersionsAsync(key, Enum.SortDirection.Ascending, 0, 0, 0):GetCurrentPage() :: any
end

function Conformance.versions()
	const store = DataStoreService:GetDataStore(`{Env.store}_ver`)
	store:SetAsync("k", 1)
	const first = listed(store, "k")[1].Version
	store:SetAsync("k", 2)
	const second = listed(store, "k")
	Env.check("versions: a write in the same hour replaces the version", #second == 1)
	Env.check("versions: the replaced id reads nil", store:GetVersionAsync("k", first) == nil)
	store:RemoveAsync("k")
	const removed = listed(store, "k")
	Env.check("versions: a remove adds a tombstone of its own", #removed == 2 and removed[2].IsDeleted)
	Env.check("versions: the tombstone reads nil", store:GetVersionAsync("k", removed[2].Version) == nil)
	Env.check("versions: the version before it still reads", store:GetVersionAsync("k", second[1].Version) == 2)
	store:SetAsync("k", 3)
	const after = listed(store, "k")
	Env.check("versions: the next write replaces the tombstone", #after == 2 and not after[2].IsDeleted)
	Env.check(
		"versions: a malformed id is error 25",
		has(
			thrown(function()
				store:GetVersionAsync("k", "not-a-version")
			end),
			"Error code: 25"
		)
	)
	const madeUp = string.gsub(second[1].Version, "%.(%d+)%.", ".0000999999.", 1)
	Env.check("versions: a well-formed id the key lacks reads nil", store:GetVersionAsync("k", madeUp) == nil)
end

function Conformance.messaging()
	const topic = `KB_LiveCheck_{Env.run}`
	const function fails(message: any, name: string?): string?
		return thrown(function()
			MessagingService:PublishAsync(name or topic, message)
		end)
	end
	Env.check("messaging: a topic of 80 characters", fails(1, string.rep("t", 80)) == nil)
	Env.check("messaging: a topic of 81 fails", has(fails(1, string.rep("t", 81)), "cannot be more than 80"))
	Env.check("messaging: a string of 1024 bytes", fails(string.rep("x", 1024)) == nil)
	Env.check("messaging: a string of 1025 fails", has(fails(string.rep("x", 1025)), "exceeded 1kb"))
	Env.check("messaging: a table of 940 JSON bytes", fails({ s = string.rep("x", 932) }) == nil)
	Env.check("messaging: a table of 941 fails", has(fails({ s = string.rep("x", 933) }), "exceeded 1kb"))
	local sent: any = nil
	const connection = MessagingService:SubscribeAsync(topic, function(message: any)
		sent = message.Sent
	end)
	MessagingService:PublishAsync(topic, 1)
	Env.waitFor(10, function(): boolean
		return sent ~= nil
	end)
	connection:Disconnect()
	Env.check("messaging: Sent has milliseconds", type(sent) == "number" and sent ~= math.floor(sent), sent)
end

function Conformance.ordered()
	const store = DataStoreService:GetOrderedDataStore(`{Env.store}_ord`)
	for _, key in { "m", "b", "x", "a", "q", "c" } do
		store:SetAsync(key, 5)
	end
	const function order(ascending: boolean): string
		const keys = {}
		for _, entry in store:GetSortedAsync(ascending, 10):GetCurrentPage() :: any do
			table.insert(keys, entry.key)
		end
		return table.concat(keys)
	end
	const descending = order(false)
	Env.check("ordered: ties come in a fixed order", order(false) == descending, descending)
	Env.check("ordered: ascending is the exact reverse", order(true) == string.reverse(descending))
	Env.check("ordered: ties are not by key", descending ~= "xqmcba" and descending ~= "abcmqx")
end

return Conformance
