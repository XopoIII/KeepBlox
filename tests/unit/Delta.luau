--!strict
--- Delta: edits between storable values, applied on another server to the record it claimed. A wrong edit
--- would store wrong play, so the round trip is checked on random values, through the JSON a MemoryStore
--- entry goes through, and the fingerprint must name equal data the same way on every server.
const Codec = require("@fakes/Codec")
const Delta = require("@keepblox/Delta")
const Prng = require("@fakes/Prng")
const Record = require("@keepblox/Record")
const Spec = require("../Spec")

const codec = Codec.new()

const WORDS = { "coins", "things", "kept", "roll", "tier", "x", "z", "note", utf8.char(0xE9), "" }

const function scalar(random: Prng.Prng): any
	const pick = random:integer(1, 5)
	if pick == 1 then
		return random:integer(-1000, 1000)
	elseif pick == 2 then
		return random:number() * 1e21
	elseif pick == 3 then
		return WORDS[random:integer(1, #WORDS)]
	elseif pick == 4 then
		return random:chance(0.5)
	end
	return -random:number()
end

-- A storable value: an array or a dictionary of string keys, nested.
const function value(random: Prng.Prng, depth: number): any
	if depth <= 0 or random:chance(0.4) then
		return scalar(random)
	end
	const out: { [any]: any } = {}
	if random:chance(0.5) then
		for index = 1, random:integer(0, 5) do
			out[index] = value(random, depth - 1)
		end
	else
		for _ = 1, random:integer(0, 5) do
			out[WORDS[random:integer(1, #WORDS)]] = value(random, depth - 1)
		end
	end
	return out
end

-- `base` changed a little, as play changes it between two writes: values set, keys added and removed,
-- arrays grown and shrunk.
const function mutate(random: Prng.Prng, base: any, depth: number): any
	if type(base) ~= "table" or random:chance(0.15) then
		return if random:chance(0.5) then base else value(random, depth)
	end
	const out = Record.copy(base)
	const isArray = #out > 0
	for key, item in out do
		if random:chance(0.3) then
			out[key] = mutate(random, item, depth - 1)
		end
	end
	if isArray then
		const roll = random:number()
		if roll < 0.3 then
			table.insert(out, value(random, depth - 1))
		elseif roll < 0.5 then
			out[#out] = nil
		end
	elseif random:chance(0.3) then
		out[WORDS[random:integer(1, #WORDS)]] = if random:chance(0.5) then nil else value(random, depth - 1)
	end
	return out
end

const function same(a: any, b: any): boolean
	return Delta.fingerprint(a) == Delta.fingerprint(b)
end

Spec.test("Delta: applying the edits to the base gives the new value, through JSON too", function()
	local checked, changed = 0, 0
	for seed = 1, 400 do
		const random = Prng.new(seed)
		const base = value(random, 4)
		const now = mutate(random, base, 4)
		const edits = Delta.diff(base, now)
		-- As another server gets them: through a MemoryStore entry's JSON, onto the record's own copy.
		const carried = codec.decode(codec.encode({ p = edits }))
		const rebuilt = Delta.apply(codec.decode(codec.encode({ d = base })).d, carried.p or {})
		Spec.truthy(Delta.fingerprint(rebuilt) == Delta.fingerprint(now), `seed {seed}: rebuilt differs`)
		checked += 1
		changed += if #edits > 0 then 1 else 0
	end
	Spec.equal(checked, 400)
	Spec.truthy(changed > 200, `only {changed} of 400 values changed: the check proves little`)
end)

Spec.test("Delta: equal values give no edits; a value changed deep inside gives one", function()
	const base = { coins = 5, things = { { roll = 0.5, tier = "Rare" }, { roll = 0.25, tier = "Epic" } } }
	Spec.equal(Delta.diff(base, Record.copy(base)), {})
	const now = Record.copy(base)
	now.things[2].roll = 0.75
	Spec.equal(Delta.diff(base, now), { { k = { "things", 2, "roll" }, v = 0.75 } })
end)

Spec.test("Delta: removals, a shrunk array and a replaced root", function()
	const base = { a = 1, list = { 1, 2, 3 }, gone = { deep = true } }
	const now = { a = 1, list = { 1 } }
	const edits = Delta.diff(base, now)
	Spec.equal(edits, { { k = { "list" }, a = 2, n = 2 }, { k = { "gone" } } }, "two items and one key removed")
	Spec.equal(Delta.apply(Record.copy(base), edits), now)
	Spec.equal(Delta.apply({ 1 }, Delta.diff({ 1 }, "text")), "text")
	Spec.equal(Delta.apply("text", Delta.diff("text", { 1 })), { 1 })
end)

Spec.test("Delta: an item taken from or put into the middle of a list is one edit", function()
	const list = {}
	for index = 1, 50 do
		table.insert(list, { roll = index / 7, tier = "Rare" })
	end
	const base = { things = list }
	const removed = Record.copy(base)
	table.remove(removed.things, 3)
	Spec.equal(Delta.diff(base, removed), { { k = { "things" }, a = 3, n = 1 } })
	Spec.equal(Delta.apply(Record.copy(base), Delta.diff(base, removed)), removed)
	const added = Record.copy(base)
	table.insert(added.things, 10, { roll = 0, tier = "Epic" })
	table.insert(added.things, 11, { roll = 1, tier = "Epic" })
	Spec.equal(
		Delta.diff(base, added),
		{ { k = { "things" }, a = 10, n = 0, v = { { roll = 0, tier = "Epic" }, { roll = 1, tier = "Epic" } } } }
	)
	Spec.equal(Delta.apply(Record.copy(base), Delta.diff(base, added)), added)
	Spec.equal(Delta.apply({ 1, 2, 3 }, Delta.diff({ 1, 2, 3 }, { 9 })), { 9 })
	Spec.equal(Delta.apply({ 1, 2, 3 }, Delta.diff({ 1, 2, 3 }, { 1, 2, 3, 4, 5 })), { 1, 2, 3, 4, 5 })
end)

Spec.test("Delta: an edit that does not fit the base is refused", function()
	Spec.equal(Delta.apply({ a = 1 }, { { k = { "b", "c" }, v = 2 } }), nil)
	Spec.equal(Delta.apply({ a = 1 }, { { k = { "a", "c" }, v = 2 } }), nil)
	Spec.equal(Delta.apply({ list = { 1, 2 } }, { { k = { "list" }, a = 2, n = 2 } }), nil, "past the end")
	Spec.equal(Delta.apply({ list = { 1, 2 } }, { { k = { "list" }, a = 0, n = 1 } }), nil, "before the start")
	Spec.equal(Delta.apply({ list = "x" }, { { k = { "list" }, a = 1, n = 0, v = { 1 } } }), nil, "not a list")
end)

Spec.test("Delta: the fingerprint names equal data the same way, whatever order it was built in", function()
	const one: any = {}
	one.b, one.a, one.list = 2, 1, { "x", "y" }
	const other: any = {}
	other.list, other.a, other.b = { "x", "y" }, 1, 2
	Spec.equal(Delta.fingerprint(one), Delta.fingerprint(other))
	Spec.equal(Delta.fingerprint({ n = -0 }), Delta.fingerprint({ n = 0 }), "0 and -0 are stored alike")
	-- Different data: a changed value, a moved key, an array against a dictionary, a string against a number.
	const differing = {
		{ a = 1, b = 3, list = { "x", "y" } },
		{ a = 1, b = 2, list = { "y", "x" } },
		{ a = 1, b = 2, list = { ["1"] = "x", ["2"] = "y" } },
		{ a = 1, b = "2", list = { "x", "y" } },
		{ a = 1, b = 2, list = { "x", "y" }, c = false },
	}
	for index, data in differing do
		Spec.truthy(Delta.fingerprint(data) ~= Delta.fingerprint(one), `variant {index} named as the original`)
	end
	for seed = 1, 200 do
		const random = Prng.new(seed)
		const data = value(random, 4)
		Spec.truthy(same(data, codec.decode(codec.encode(data))), `seed {seed}: JSON changed the name`)
	end
end)

return nil
