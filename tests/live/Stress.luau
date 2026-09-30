--!strict
--- Load: many virtual servers, hundreds of profiles, players moving and servers crashing, all on this
--- one server's real budget and the test experience's limits. It is meant to overload: 300 profiles on
--- a budget for one player. What must hold anyway: never two live owners of a key; a hand-over carries
--- the data exactly; a crash loses at most one beat of play; every load answers (a profile or a
--- reason) within its deadline; what is stored at the end is what each key's last owner held.
const Env = require("./Env")

export type Options = {
	servers: number?,
	players: number?,
	play: number?,
	moveEvery: number?,
	crashAt: { number }?,
	messagesPerMinute: number?,
}

const Stress = {}

const TYPES = { "StandardRead", "StandardWrite", "StandardList" }

-- One token bucket for every virtual server's publishes: the experience's message quotas are shared,
-- so the test never sends more than `perMinute`. Extra publishes are dropped, as lost messages are.
const function capMessaging(servers: { Env.Server }, perMinute: number): () -> (number, number)
	local tokens, at, sent, dropped = perMinute, os.clock(), 0, 0
	for _, server in servers do
		const inner = server.services.messaging
		server.services.messaging = {
			PublishAsync = function(self: any, topic: string, message: any)
				tokens = math.min(perMinute, tokens + (os.clock() - at) * perMinute / 60)
				at = os.clock()
				if tokens < 1 then
					dropped += 1
					return
				end
				tokens -= 1
				sent += 1
				inner.PublishAsync(self, topic, message)
			end,
			SubscribeAsync = inner.SubscribeAsync,
		}
	end
	return function(): (number, number)
		return sent, dropped
	end
end

type Held = { server: number, profile: any }

function Stress.run(options: Options)
	const count, perServer, play = options.servers or 10, options.players or 30, options.play or 180
	const crashAt = options.crashAt or { 60, 120 }
	const storeName = `{Env.store}_stress`
	const servers: { Env.Server } = {}
	for index = 1, count do
		servers[index] = Env.server(`S{index}`)
	end
	const messages = capMessaging(servers, options.messagesPerMinute or 60)
	const stores = {}
	const problems: { [string]: number } = {}
	for index, server in servers do
		stores[index] = server.open(storeName, { template = { coins = 0 } })
		stores[index].onError:connect(function(_: string, message: string)
			const kind = string.sub((string.gsub(message, "st_%d+_%d+", "<key>")), 1, 80)
			problems[kind] = (problems[kind] or 0) + 1
		end)
	end
	const owner: { [string]: Held } = {}
	const truth: { [string]: number } = {}
	const held: { [string]: { Held } } = {}
	const pending: { [number]: number } = {}
	const times: { number } = {}
	const failed: { [string]: number } = {}
	local loads, overlaps, wrongCarry, crashKeys, mostLost = 0, 0, 0, 0, 0

	const function alive(index: number): boolean
		return not servers[index].dead
	end
	const function claim(key: string, index: number)
		pending[index] = (pending[index] or 0) + 1
		const began = os.clock()
		const result = stores[index]:load(key)
		pending[index] -= 1
		table.insert(times, os.clock() - began)
		if not result.ok then
			failed[result.reason] = (failed[result.reason] or 0) + 1
			return
		end
		loads += 1
		const profile = result.profile
		for _, other in held[key] or {} do
			if other.profile ~= profile and alive(other.server) and other.profile:isActive() then
				overlaps += 1
				Env.log(`OVERLAP {key}: server {other.server} still active as {index} loaded it`)
			end
		end
		const previous = owner[key]
		const expected = truth[key] or 0
		if previous and not alive(previous.server) then
			crashKeys += 1
			mostLost = math.max(mostLost, expected - profile.Data.coins)
		elseif profile.Data.coins ~= expected then
			wrongCarry += 1
			Env.log(`CARRY {key}: loaded {profile.Data.coins}, truth {expected}`)
		end
		truth[key] = profile.Data.coins
		owner[key] = { server = index, profile = profile }
		held[key] = held[key] or {}
		table.insert(held[key], owner[key])
	end
	-- Loads still waiting on live servers (a crashed server's loads never return, by design).
	const function waiting(): number
		local total = 0
		for index, n in pending do
			if alive(index) then
				total += n
			end
		end
		return total
	end
	const function report(label: string)
		const sent, dropped = messages()
		Env.log(
			`STRESS {label}: loaded {loads}, waiting {waiting()}, failed {Env.encode(failed)}, overlaps {overlaps}, `
				.. `messages {sent} sent {dropped} dropped, budget {Env.budget(TYPES)}`
		)
	end

	const keys: { string } = {}
	for index = 1, count do
		for slot = 1, perServer do
			const key = `st_{index}_{slot}`
			table.insert(keys, key)
			task.spawn(claim, key, index)
		end
	end
	Env.log(`STRESS {count} servers x {perServer} players = {#keys} profiles, budget {Env.budget(TYPES)}`)
	Env.waitFor(300, function(): boolean
		return waiting() == 0
	end)
	report("after the joins")

	local playing = true
	task.spawn(function()
		while playing do
			for _, key in keys do
				const current = owner[key]
				if current and alive(current.server) and current.profile:isActive() then
					if pcall(function()
						current.profile.Data.coins += 1
					end) then
						truth[key] = current.profile.Data.coins
					end
				end
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		while playing do
			const key = keys[math.random(#keys)]
			const current, target = owner[key], math.random(count)
			if current and target ~= current.server and alive(target) then
				task.spawn(claim, key, target)
			end
			task.wait(options.moveEvery or 1)
		end
	end)
	for order, at in crashAt do
		task.delay(at, function()
			const victim = order * 3
			servers[victim].crash()
			local orphans = 0
			for _, key in keys do
				const current = owner[key]
				if current and current.server == victim then
					orphans += 1
					task.spawn(claim, key, victim % count + 1)
				end
			end
			Env.log(`STRESS server {victim} crashed at {at} s: {orphans} keys to take over`)
		end)
	end
	for elapsed = 30, play, 30 do
		task.wait(30)
		report(`t+{elapsed} s`)
	end
	playing = false
	const settled = Env.waitFor(180, function(): boolean
		return waiting() == 0
	end)
	const closing = os.clock()
	for index, store in stores do
		if alive(index) then
			store:close()
		end
	end
	Env.log(`STRESS closed in {string.format("%.1f", os.clock() - closing)} s`)
	local wrong, unread = 0, 0
	const locked: { string } = {}
	for _, key in keys do
		const current = owner[key]
		if current and alive(current.server) then
			local ok, raw = false, nil
			for _ = 1, 10 do
				ok, raw = pcall(Env.raw, storeName, key)
				if ok then
					break
				end
				task.wait(3)
			end
			if not ok then
				unread += 1
			elseif raw.Data.coins ~= truth[key] then
				wrong += 1
			elseif raw.MetaData.ActiveSession ~= nil then
				table.insert(locked, key)
			end
		end
	end
	-- A release that missed the shutdown deadline (the budget was spent) leaves its lock: the next server
	-- must take the key over once the closed server's beat stops, with the data intact.
	local recovered = 0
	if #locked > 0 then
		const heir = Env.server("heir").open(storeName, { template = { coins = 0 } })
		for _, key in locked do
			const result = heir:load(key)
			if result.ok and result.profile.Data.coins == truth[key] then
				recovered += 1
				result.profile:release()
			end
		end
	end
	table.sort(times)
	const longest = times[#times] or 0
	const kinds = {}
	for kind, n in problems do
		table.insert(kinds, `{n}x {kind}`)
	end
	table.sort(kinds)
	Env.log(`STRESS errors: {table.concat(kinds, " || ")}`)
	Env.log(
		`MEASURE stress: {loads} loaded, failed {Env.encode(failed)}, longest load {string.format("%.1f", longest)} s`
	)
	Env.check("stress: never two live owners of a key", overlaps == 0, overlaps)
	Env.check("stress: every hand-over carried the data exactly", wrongCarry == 0, wrongCarry)
	Env.check("stress: a crash lost at most one beat of play", mostLost <= 3, `{crashKeys} takeovers, {mostLost}`)
	Env.check("stress: every load on a live server answered", settled, waiting())
	Env.check("stress: no load past its deadline (120 s, and a call)", longest <= 141, longest)
	Env.check("stress: stored data is the last owner's", wrong == 0 and unread == 0, `wrong {wrong}, unread {unread}`)
	Env.log(`MEASURE stress: {#locked} locks left by a shutdown on a spent budget`)
	Env.check("stress: a key a shutdown left locked is taken over with its data", recovered == #locked, recovered)
end

return Stress
