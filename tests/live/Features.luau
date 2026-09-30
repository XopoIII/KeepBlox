--!strict
--- Live checks of the features: messages, receipts, versions, releases that roll back, trades,
--- compression, and mixed ProfileStore servers.
const Env = require("./Env")

const Features = {}

const GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

function Features.messages()
	const a, b = Env.server("A").open(), Env.server("B").open()
	Env.check("messages: send #1 to a free key", b:message("msg", { gift = 1 }).ok)
	Env.check("messages: send #2 to a free key", b:message("msg", { gift = 2 }).ok)
	const loaded = a:load("msg")
	if not Env.check("messages: A loads", loaded.ok, loaded.reason) then
		return
	end
	const profile = loaded.profile
	const got: { number } = {}
	profile:onMessage(function(message: any, processed: () -> ())
		table.insert(got, message.gift)
		profile.Data.coins += message.gift
		processed()
	end)
	Env.waitFor(10, function(): boolean
		return #got >= 2
	end)
	Env.check("messages: both offline messages, once", #got == 2 and profile.Data.coins == 3, Env.encode(got))
	profile:save()
	Env.check("messages: send #3 while A holds it", b:message("msg", { gift = 10 }).ok)
	const live, took = Env.waitFor(60, function(): boolean
		return #got >= 3
	end)
	Env.check("messages: an online message arrives", live, `{string.format("%.2f", took)} s`)
	profile:release()
	const again = a:load("msg")
	if again.ok then
		local repeated = 0
		again.profile:onMessage(function(_: any, processed: () -> ())
			repeated += 1
			processed()
		end)
		task.wait(4)
		Env.check("messages: none twice after a reload", repeated == 0 and again.profile.Data.coins == 13)
		again.profile:release()
	end
end

function Features.receipts()
	const store = Env.server("A").open()
	const process = Env.KeepBlox.processReceipt(store, {
		keyFor = function(userId: number): string
			return `rc_{userId}`
		end,
		products = {
			[1] = function(profile: any)
				profile.Data.coins += 100
			end,
		},
	})
	Env.check(
		"receipts: a player not here is NotProcessedYet",
		process({ PlayerId = 43, PurchaseId = "P0", ProductId = 1 }) == Enum.ProductPurchaseDecision.NotProcessedYet
	)
	const loaded = store:load("rc_42")
	if not Env.check("receipts: loads", loaded.ok, loaded.reason) then
		return
	end
	const receipt = { PlayerId = 42, PurchaseId = `P1-{Env.run}`, ProductId = 1 }
	Env.check("receipts: granted", process(receipt) == GRANTED)
	Env.check(
		"receipts: a repeat is granted, not doubled",
		process(receipt) == GRANTED and loaded.profile.Data.coins == 100
	)
	Env.check("receipts: stored before granted", Env.raw(Env.store, "rc_42").Data.coins == 100)
	loaded.profile:release()
end

function Features.versions()
	const store = Env.server("A").open()
	const loaded = store:load("ver")
	if not Env.check("versions: loads", loaded.ok, loaded.reason) then
		return
	end
	for coins = 1, 3 do
		loaded.profile.Data.coins = coins
		loaded.profile:save()
	end
	const listed = store:versions("ver", {})
	Env.check("versions: listed", #listed >= 1, #listed)
	const newest = listed[#listed].version
	Env.check("versions: restore refused while held", store:restore("ver", newest).reason == "inUse")
	Env.check(
		"versions: an id that is not one is noVersion",
		store:restore("ver", "not-a-version").reason == "noVersion"
	)
	loaded.profile.Data.coins = 99
	loaded.profile:release()
	-- The release wrote in the same hour, so the version listed above is gone (Roblox keeps one an hour).
	Env.check("versions: an overwritten version is noVersion", store:restore("ver", newest).reason == "noVersion")
	const current = store:versions("ver", {})
	const restored = store:restore("ver", current[#current].version)
	Env.check("versions: the current version restores", restored.ok, Env.encode(restored))
	const again = store:load("ver")
	if again.ok then
		Env.check("versions: the restored data loads", again.profile.Data.coins == 99, again.profile.Data.coins)
		again.profile:release()
	end
end

function Features.migrations()
	const name = `{Env.store}_mig`
	const old = Env.server("A").open(name, { template = { coins = 0 } })
	const first = old:load("m")
	if not Env.check("migrations: the old release loads", first.ok, first.reason) then
		return
	end
	first.profile.Data.coins = 5
	first.profile:release()
	const migrations = {
		[1] = {
			up = function(data: any)
				data.gold, data.coins = data.coins, nil
			end,
			down = function(data: any)
				data.coins, data.gold = data.gold, nil
			end,
		},
	}
	const rolling = Env.server("B")
		.open(name, { template = { gold = 0 }, version = 1, writeVersion = 0, migrations = migrations })
	const second = rolling:load("m")
	if Env.check("migrations: the new release reads old data", second.ok and second.profile.Data.gold == 5) then
		second.profile.Data.gold = 6
		second.profile:release()
	end
	const raw = Env.raw(name, "m")
	Env.check("migrations: writeVersion 0 stores the old shape", raw.Data.coins == 6 and raw.Data.gold == nil)
	const third = old:load("m")
	Env.check("migrations: the old release reads it back", third.ok and third.profile.Data.coins == 6)
	if third.ok then
		third.profile:release()
	end
	const newer = Env.server("C").open(name, { template = { gold = 0 }, version = 1, migrations = migrations })
	const fourth = newer:load("m")
	if fourth.ok then
		fourth.profile:release()
	end
	const fifth = old:load("m")
	Env.check("migrations: the old release refuses data stored at v1", fifth.reason == "newerSchema", fifth.reason)
	if fifth.ok then
		fifth.profile:release()
	end
end

function Features.trade()
	const store = Env.server("A").open()
	const a, b = store:load("tA"), store:load("tB")
	if not Env.check("trade: loads", a.ok and b.ok) then
		return
	end
	a.profile.Data.coins = 100
	Env.check(
		"trade: ok",
		store:trade("tA", "tB", function(x: any, y: any)
			x.coins -= 30
			y.coins += 30
		end).ok
	)
	const refused = store:trade("tA", "tB", function(x: any, y: any)
		x.coins -= 1000
		y.coins += 1000
		error("refuse")
	end)
	Env.check("trade: a throwing change is undone", not refused.ok and a.profile.Data.coins == 70)
	a.profile:release()
	b.profile:release()
	Env.check(
		"trade: stored 70 / 30",
		Env.raw(Env.store, "tA").Data.coins == 70 and Env.raw(Env.store, "tB").Data.coins == 30
	)
end

function Features.compress()
	const name = `{Env.store}_zip`
	const store = Env.server("A").open(name, { template = { blob = "" }, compress = { above = 200 } })
	const loaded = store:load("big")
	if not Env.check("compress: loads", loaded.ok, loaded.reason) then
		return
	end
	const blob = string.rep("abcdefgh", 4000)
	loaded.profile.Data.blob = blob
	loaded.profile:release()
	Env.check("compress: stored compressed", Env.raw(name, "big").Data.__KeepBlox == "zstd1")
	const again = store:load("big")
	Env.check("compress: reads back exactly", again.ok and again.profile.Data.blob == blob)
	if again.ok then
		again.profile:release()
	end
end

--> `ProfileStore` is the vendored module (tests/reference), running on this server's real services.
function Features.profileStore(ProfileStore: any)
	const name = `{Env.store}_ps`
	const ps = ProfileStore.New(name, { coins = 0 })
	const store = Env.server("B").open(name, { template = { coins = 0 } })
	const held = ps:StartSessionAsync("ps1")
	if not Env.check("interop: ProfileStore opens ps1", held ~= nil) then
		return
	end
	held.Data.coins = 3
	local began = os.clock()
	const taken = store:load("ps1")
	if
		Env.check(
			"interop: KeepBlox takes ps1 from live ProfileStore",
			taken.ok,
			`{string.format("%.2f", os.clock() - began)} s`
		)
	then
		Env.check("interop: ProfileStore's unsaved coins carried", taken.profile.Data.coins == 3)
		taken.profile.Data.coins = 4
		taken.profile:release()
	end
	const ours = store:load("ps2")
	if not Env.check("interop: KeepBlox opens ps2", ours.ok) then
		return
	end
	ours.profile.Data.coins = 5
	began = os.clock()
	const theirs = ps:StartSessionAsync("ps2")
	if
		Env.check(
			"interop: ProfileStore takes ps2 from live KeepBlox",
			theirs ~= nil,
			`{string.format("%.2f", os.clock() - began)} s`
		)
	then
		Env.check("interop: KeepBlox's unsaved coins carried", theirs.Data.coins == 5)
		theirs:EndSession()
	end
	const back = ps:StartSessionAsync("ps1")
	if Env.check("interop: ProfileStore reads KeepBlox's write", back ~= nil and back.Data.coins == 4) then
		back:EndSession()
	end
end

return Features
