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

Spec.test("Encoding: undocumented cases are refused as unmodelled, not guessed", function()
	for _, value in { 0 / 0, math.huge, -math.huge } do
		Spec.throws(function()
			Encoding.encode({ value })
		end, "UNMODELLED: storing the number")
	end
	-- Built in two steps: the refusal of a mixed table is what is under test.
	const mixed: { [any]: any } = { 1, 2 }
	mixed.extra = true
	Spec.throws(function()
		Encoding.encode(mixed)
	end, "UNMODELLED: a table with a number key")
	Spec.throws(function()
		Encoding.encode({ [1] = "a", [3] = "c" })
	end, "UNMODELLED: a table with a number key")
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
