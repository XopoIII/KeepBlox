--!strict
const Spec = require("../Spec")
const Validate = require("@keepblox/Validate")

const function refused(value: any): string
	const encoded, problem = Validate.check(value, "Data")
	Spec.equal(encoded, nil, "refused")
	return problem :: string
end

Spec.test("Validate: good data encodes canonically, keys sorted", function()
	const encoded = Validate.check({ b = { 1, 2.5, true }, a = "x" }, "Data")
	assert(encoded, "accepted")
	Spec.equal(encoded.text, '{"a":"x","b":[1,2.5,true]}')
	Spec.equal(encoded.size, #'{"a":"x","b":[1,2.5,true]}')
end)

Spec.test("Validate: equal data gives equal text, whatever the insertion order", function()
	const first, second = { x = 1, y = 2, z = { k = "v" } }, {}
	second.z = { k = "v" }
	second.y = 2
	second.x = 1
	Spec.equal((Validate.check(first, "Data") :: any).text, (Validate.check(second, "Data") :: any).text)
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

return nil
