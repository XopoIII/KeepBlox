--!strict
const Spec = require("../Spec")
const Validate = require("@keepblox/Validate")

const function refused(value: any): string
	const encoded, problem = Validate.check(value, "Data")
	Spec.equal(encoded, nil, "refused")
	return problem :: string
end

Spec.test("Validate: the size is the stored JSON length", function()
	const encoded = Validate.check({ b = { 1, 2.5, true }, a = "x" }, "Data")
	assert(encoded, "accepted")
	Spec.equal(encoded.size, #'{"a":"x","b":[1,2.5,true]}')
	Spec.equal((Validate.check('say "hi"\n', "Data") :: any).size, #'"say \\"hi\\"\\n"')
end)

Spec.test("Validate: an unchanged table encodes the same; any change shows in the text", function()
	const data = { x = 1, list = { "a", "b" }, nested = { k = "v" } }
	const first = (Validate.check(data, "Data") :: any).text
	Spec.equal((Validate.check(data, "Data") :: any).text, first)
	for _, change in
		{
			function()
				data.x = 2
			end,
			function()
				data.list[3] = "c"
			end,
			function()
				data.nested.k = "w"
			end,
			function()
				data.list[1] = "a,b"
			end,
		}
	do
		const before = (Validate.check(data, "Data") :: any).text
		change()
		Spec.truthy((Validate.check(data, "Data") :: any).text ~= before, "the text changed")
	end
end)

Spec.test("Validate: strings that look alike in the text still differ", function()
	const a = (Validate.check({ "a", "b" }, "Data") :: any).text
	const b = (Validate.check({ 'a","b' }, "Data") :: any).text
	Spec.truthy(a ~= b, "an embedded quote and comma cannot forge a second string")
end)

Spec.test("Validate: pause is called while a large value is checked", function()
	const big = table.create(3000, 1)
	local pauses = 0
	Validate.check(big, "Data", nil, function()
		pauses += 1
	end)
	Spec.equal(pauses, 5)
end)

Spec.test("Validate: every refusal names the path of the bad value", function()
	Spec.equal(
		refused({ inventory = { { name = "ok" }, { name = "\xFF" } } }),
		"Data.inventory[2].name: string is not valid UTF-8"
	)
	Spec.equal(refused({ stats = { speed = 0 / 0 } }), "Data.stats.speed: NaN cannot be stored")
	Spec.equal(refused({ stats = { speed = -math.huge } }), "Data.stats.speed: infinity cannot be stored")
	Spec.equal(refused({ callback = print }), "Data.callback: function cannot be stored")
	Spec.equal(refused({ [5] = true, name = "x" }), "Data.5: number key in a table that is not an array")
	Spec.equal(refused({ list = { [1] = 1, [3] = 3 } }), "Data.list.1: number key in a table that is not an array")
	Spec.equal(refused({ ["\xFE"] = 1 }), "Data: a key is not valid UTF-8")
end)

Spec.test("Validate: a cycle is refused, a shared table is not", function()
	const loop: { [string]: any } = {}
	loop.self = loop
	Spec.equal(refused({ loop = loop }), "Data.loop.self: table contains itself (a cycle)")
	const shared = { 1 }
	Spec.truthy(Validate.check({ a = shared, b = shared }, "Data") ~= nil, "a shared table is fine")
end)

Spec.test("Validate: the size limit is exact and configurable", function()
	-- A string of n bytes encodes to n + 2.
	Spec.truthy(Validate.check(string.rep("x", 98), "Data", 100) ~= nil, "at the limit")
	Spec.equal(
		select(2, Validate.check(string.rep("x", 99), "Data", 100)),
		"Data: about 101 bytes, over the 100 byte limit"
	)
	Spec.equal(Validate.LIMIT, 4_194_304)
end)

Spec.test("Validate: a buffer counts as base64, and its bytes decide equality", function()
	const a, b = buffer.create(3), buffer.create(3)
	buffer.writeu8(b, 0, 1)
	const first, second = Validate.check({ blob = a }, "Data"), Validate.check({ blob = b }, "Data")
	assert(first and second, "accepted")
	Spec.truthy(first.text ~= second.text, "different bytes, different text")
	Spec.equal(first.size, #'{"blob":}' + #'{"m":null,"t":"buffer","base64":""}' + 4)
end)

Spec.test("Validate: the check says whether the data holds a buffer", function()
	-- Packing decides on this flag (src/Codec.luau): a buffer cannot be compressed, and finding one
	-- must not cost a second walk of the data.
	Spec.equal((Validate.check({ blob = buffer.create(4) }, "Data") :: any).hasBuffer, true)
	Spec.equal(
		(Validate.check({ list = { 1, { deep = { blob = buffer.create(1) } } } }, "Data") :: any).hasBuffer,
		true
	)
	Spec.equal((Validate.check({ list = { 1, { deep = "x" } } }, "Data") :: any).hasBuffer, false)
	Spec.equal((Validate.check("plain", "Data") :: any).hasBuffer, false)
end)

Spec.test("Validate: a value of many parts is joined exactly as a small one", function()
	-- Past a few thousand parts the text is joined a chunk at a time, inside the sliced walk.
	for _, count in { 4094, 4095, 4096, 4097, 10_000 } do
		const items = table.create(count)
		for index = 1, count do
			items[index] = index
		end
		const encoded = Validate.check(items, "Data", nil, function() end)
		Spec.equal((encoded :: any).text, "[," .. table.concat(items, ",") .. ",]", `{count} items`)
	end
end)

return nil
