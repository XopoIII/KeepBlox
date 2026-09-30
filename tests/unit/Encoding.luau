--!strict
const Encoding = require("@fakes/Encoding")
const Spec = require("../Spec")

Spec.test("Encoding: scalars, arrays and dictionaries encode as JSONEncode does", function()
	Spec.equal(Encoding.encode(nil), "null")
	Spec.equal(Encoding.encode(true), "true")
	Spec.equal(Encoding.encode(42), "42")
	Spec.equal(Encoding.encode(-7), "-7")
	Spec.equal(Encoding.encode(0.1), "0.1")
	Spec.equal(Encoding.encode(1 / 3), "0.3333333333333333")
	Spec.equal(Encoding.encode('a"b\\c\n'), '"a\\"b\\\\c\\n"')
	Spec.equal(Encoding.encode("\1"), '"\\u0001"')
	Spec.equal(Encoding.encode({ 1, 2, 3 }), "[1,2,3]")
	Spec.equal(Encoding.encode({}), "[]")
	Spec.equal(Encoding.encode({ b = 1, a = { true } }), '{"a":[true],"b":1}')
end)

Spec.test("Encoding: size is the byte length of the JSON text", function()
	Spec.equal(Encoding.size({ coins = 10 }), #'{"coins":10}')
	-- Two-byte UTF-8 characters count as two bytes each.
	Spec.equal(Encoding.size("\u{00E9}\u{00E9}"), 6)
	Spec.equal(Encoding.size(buffer.create(3)), #'{"m":null,"t":"buffer","base64":""}' + 4)
	Spec.equal(Encoding.size(buffer.create(4)), #'{"m":null,"t":"buffer","base64":""}' + 8)
end)

Spec.test("Encoding: refuses what a data store cannot hold, naming the path", function()
	Spec.throws(function()
		Encoding.encode({ name = "ok", bad = "\xFF" })
	end, "104: Cannot store a string that is not valid UTF-8 (at value.bad)")
	Spec.throws(function()
		Encoding.encode({ list = { 1, function() end } })
	end, "104: Cannot store a function (at value.list[2])")
	const cyclic: { [string]: any } = {}
	cyclic.self = cyclic
	Spec.throws(function()
		Encoding.encode(cyclic)
	end, "a cyclic table (at value.self)")
	Spec.throws(function()
		Encoding.encode({ ["\xFE"] = 1 })
	end, "a key that is not valid UTF-8")
end)

-- Each case below was stored and read back live (Studio, 2026-09-30).
Spec.test("Encoding: NaN and infinities are stored in the engine's numeric wrapper and read back", function()
	Spec.equal(Encoding.encode({ 0 / 0 }), '[{"m":null,"t":"numeric","v":"nan"}]')
	Spec.equal(Encoding.encode(math.huge), '{"m":null,"t":"numeric","v":"inf"}')
	Spec.equal(Encoding.encode(-math.huge), '{"m":null,"t":"numeric","v":"-inf"}')
	Spec.equal(Encoding.stored({ v = math.huge }).v, math.huge)
	const nan = Encoding.stored({ v = 0 / 0 }).v
	Spec.truthy(nan ~= nan, "NaN reads back as NaN")
end)

Spec.test("Encoding: a table with [1] is stored as its array part; every other key is lost silently", function()
	-- Built in steps: the table's shape is what is under test.
	const mixed: { [any]: any } = { 1, 2 }
	mixed.x = 3
	Spec.equal(Encoding.encode(mixed), "[1,2]")
	Spec.equal(Encoding.stored(mixed), { 1, 2 })
	Spec.equal(Encoding.encode({ [1] = 1, [3] = 3 }), "[1]")
	Spec.equal(Encoding.stored({ inner = { [1] = 1, [3] = 3 } }), { inner = { 1 } })
	const text: { [any]: any } = { [1] = "a" }
	text["1"] = "b"
	Spec.equal(Encoding.encode(text), '["a"]')
	const holes: { [any]: any } = { 1, 2 }
	holes[4] = 4
	Spec.equal(Encoding.encode(holes), "[1,2,null,4]")
	Spec.equal(Encoding.size(mixed), 5)
end)

Spec.test("Encoding: other tables are dictionaries; number keys become integer text, boolean keys fail", function()
	Spec.equal(Encoding.encode({ [2] = 5 }), '{"2":5}')
	Spec.equal(Encoding.encode({ [0] = 1 }), '{"0":1}')
	Spec.equal(Encoding.encode({ [-1] = 1 }), '{"-1":1}')
	Spec.equal(Encoding.encode({ [2.5] = 1 }), '{"2":1}')
	Spec.equal(Encoding.encode({ [1e20] = 1 }), '{"9223372036854775807":1}')
	const mixed: { [any]: any } = { x = 2 }
	mixed[1.5] = 1
	Spec.equal(Encoding.encode(mixed), '{"1":1,"x":2}')
	Spec.equal(Encoding.stored(mixed), { ["1"] = 1, x = 2 })
	Spec.throws(function()
		Encoding.encode({ [true] = 1 })
	end, "Invalid table key type used")
	-- Not seen live: two keys that land on the same text.
	const clash: { [any]: any } = { ["2"] = 1 }
	clash[2.5] = 2
	Spec.throws(function()
		Encoding.encode(clash)
	end, 'UNMODELLED: two keys stored as "2"')
end)

Spec.test("Encoding: a shared table is not a cycle", function()
	const shared = { 1 }
	Spec.equal(Encoding.encode({ a = shared, b = shared }), '{"a":[1],"b":[1]}')
end)

Spec.test("Encoding: copy shares nothing with the original", function()
	const original = { inventory = { { name = "sword" } }, blob = buffer.create(2) }
	const copied = Encoding.copy(original)
	Spec.equal(copied.inventory, original.inventory)
	Spec.truthy(copied.inventory ~= original.inventory, "tables are new")
	Spec.truthy(copied.blob ~= original.blob, "buffers are new")
	copied.inventory[1].name = "bow"
	buffer.writeu8(copied.blob, 0, 9)
	Spec.equal(original.inventory[1].name, "sword")
	Spec.equal(buffer.readu8(original.blob, 0), 0)
end)

return nil
