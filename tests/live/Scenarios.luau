--!strict
--- Live scenarios of the session lock: the public API over the real services.
const Env = require("./Env")

const Scenarios = {}

const function f2(value: number): string
	return string.format("%.2f", value)
end

function Scenarios.roundtrip()
	const a, b = Env.server("A").open(), Env.server("B").open()
	local began = os.clock()
	const loaded = a:load("round")
	if not Env.check("roundtrip: A loads a new key", loaded.ok, `{f2(os.clock() - began)} s`) then
		return
	end
	const profile = loaded.profile
	profile.Data.coins = 5
	profile.Data.list = { 1, 2, 3 }
	profile.Data.name = "\u{E9} \u{2713} \u{6F22}"
	local ended: string? = nil
	profile.onEnded:connect(function(reason: string)
		ended = reason
	end)
	began = os.clock()
	Env.check("roundtrip: save() returns true", profile:save() == true, `{f2(os.clock() - began)} s`)
	profile:release()
	Env.check("roundtrip: release ends 'released'", ended == "released", ended)
	Env.check("roundtrip: Data frozen after release", table.isfrozen(profile.Data))
	const raw = Env.raw(Env.store, "round")
	Env.check("roundtrip: stored coins 5", raw.Data.coins == 5, raw.Data.coins)
	Env.check("roundtrip: stored lock released", raw.MetaData.ActiveSession == nil)
	began = os.clock()
	const again = b:load("round")
	if Env.check("roundtrip: B loads it", again.ok, `{f2(os.clock() - began)} s`) then
		const data = again.profile.Data
		Env.check(
			"roundtrip: B reads exact data",
			data.coins == 5 and #data.list == 3 and data.list[3] == 3 and data.name == "\u{E9} \u{2713} \u{6F22}",
			Env.encode(data)
		)
		Env.check("roundtrip: loadCount 2", again.profile.loadCount == 2, again.profile.loadCount)
		again.profile:release()
	end
end

function Scenarios.handover()
	const a, b = Env.server("A").open(), Env.server("B").open()
	const loaded = a:load("handover")
	if not Env.check("handover: A loads", loaded.ok, loaded.reason) then
		return
	end
	const profile = loaded.profile
	local ended: string? = nil
	profile.onEnded:connect(function(reason: string)
		ended = reason
	end)
	profile.Data.coins = 7 -- not saved: the hand-over must carry it
	task.wait(5) -- let A beat at least once
	const began = os.clock()
	const taken = b:load("handover")
	const took = os.clock() - began
	if Env.check("handover: B gets the key from live A", taken.ok, `{f2(took)} s`) then
		Env.check("handover: unsaved change carried", taken.profile.Data.coins == 7, taken.profile.Data.coins)
		Env.check("handover: A ended 'handedOver'", ended == "handedOver", ended)
		Env.check("handover: A inactive and frozen", not profile:isActive() and table.isfrozen(profile.Data))
		Env.log(`MEASURE handover from a live owner: {f2(took)} s`)
		taken.profile:release()
	end
end

type Span = { name: string, from: number, to: number?, reason: string? }

function Scenarios.race()
	const stores = { Env.server("A").open(), Env.server("B").open(), Env.server("C").open() }
	const spans: { Span } = {}
	const function track(name: string, profile: any)
		const span: Span = { name = name, from = os.clock() }
		table.insert(spans, span)
		profile.Data.coins += 1
		profile.onEnded:connect(function(reason: string)
			span.to, span.reason = os.clock(), reason
		end)
	end
	const first = stores[1]:load("race")
	if not Env.check("race: A loads", first.ok, first.reason) then
		return
	end
	track("A", first.profile)
	task.wait(5)
	const results: { [number]: any } = {}
	for index = 2, 3 do
		task.spawn(function()
			const result = stores[index]:load("race")
			results[index] = result
			if result.ok then
				track(if index == 2 then "B" else "C", result.profile)
			end
		end)
	end
	Env.check("race: both loads returned", (Env.waitFor(150, function(): boolean
		return results[2] ~= nil and results[3] ~= nil
	end)))
	table.sort(spans, function(x: Span, y: Span): boolean
		return x.from < y.from
	end)
	local overlap, open = false, 0
	for index, span in spans do
		const nextSpan = spans[index + 1]
		if nextSpan and (span.to == nil or (span.to :: number) > nextSpan.from) then
			overlap = true
		end
		if span.to == nil then
			open += 1
		end
	end
	Env.check("race: never two owners at once", not overlap)
	Env.check("race: exactly one owner at the end", open == 1, open)
	for index = 2, 3 do
		const result = results[index]
		if result and result.ok and result.profile:isActive() then
			Env.check("race: the final owner has every session's +1", result.profile.Data.coins == #spans)
			result.profile:release()
		end
	end
end

function Scenarios.crash()
	const serverA = Env.server("A")
	const a, b = serverA.open(), Env.server("B").open()
	const loaded = a:load("crash")
	if not Env.check("crash: A loads", loaded.ok, loaded.reason) then
		return
	end
	local step = 0
	for _ = 1, 24 do -- a change every 0.5 s for 12 s
		step += 1
		loaded.profile.Data.coins = step
		task.wait(0.5)
	end
	serverA.crash()
	const began = os.clock()
	const taken = b:load("crash")
	const took = os.clock() - began
	if Env.check("crash: B takes the dead owner's key", taken.ok, `{f2(took)} s`) then
		const lost = step - taken.profile.Data.coins
		Env.check("crash: at most one beat of play lost (10 steps of 0.5 s)", lost >= 0 and lost <= 10, lost)
		Env.log(`MEASURE crash takeover: {f2(took)} s, lost {lost} steps of 0.5 s`)
		taken.profile:release()
	end
end

function Scenarios.shutdown()
	const store = Env.server("A").open()
	local loaded = 0
	for index = 1, 5 do
		task.spawn(function()
			const result = store:load(`sd{index}`)
			if result.ok then
				result.profile.Data.coins = index * 10
				loaded += 1
			end
		end)
	end
	Env.waitFor(60, function(): boolean
		return loaded == 5
	end)
	Env.check("shutdown: 5 loads", loaded == 5, loaded)
	const began = os.clock()
	store:close()
	const took = os.clock() - began
	Env.log(`MEASURE shutdown of 5 profiles: {f2(took)} s`)
	Env.check("shutdown: close() within 25 s", took < 25, `{f2(took)} s`)
	for index = 1, 5 do
		const raw = Env.raw(Env.store, `sd{index}`)
		Env.check(
			`shutdown: sd{index} saved and unlocked`,
			raw ~= nil and raw.Data.coins == index * 10 and raw.MetaData.ActiveSession == nil
		)
	end
end

return Scenarios
