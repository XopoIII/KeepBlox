--!strict
const Schema = require("@keepblox/Schema")
const Spec = require("../Spec")

const S = Schema
const PROFILE = S.record({
	coins = S.number({ default = 10, min = 0, integer = true }),
	name = S.string({ default = "guest", maxLength = 8 }),
	music = S.boolean({ default = true }),
	rank = S.enum({ "bronze", "silver", "gold" }),
	inventory = S.array(
		S.record({ id = S.string(), level = S.number({ default = 1, min = 1, max = 100 }) }),
		{ max = 3 }
	),
	pets = S.map(S.record({ age = S.number() }), { max = 2 }),
	banned = S.optional(S.boolean()),
	extra = S.record({}, { open = true }),
})

Spec.test("Schema: defaults compose from the fields; optional fields are absent", function()
	Spec.equal(Schema.default(PROFILE), {
		coins = 10,
		name = "guest",
		music = true,
		rank = "bronze",
		inventory = {},
		pets = {},
		extra = {},
	})
	Spec.equal(Schema.check(PROFILE, Schema.default(PROFILE)), nil)
end)

Spec.test("Schema: every rule names the path of the value that breaks it", function()
	const function broken(change: (data: any) -> ()): string?
		const data = Schema.default(PROFILE)
		change(data)
		return Schema.check(PROFILE, data)
	end
	Spec.equal(
		broken(function(d)
			d.coins = "7"
		end),
		"Data.coins: expected a number, got string"
	)
	Spec.equal(
		broken(function(d)
			d.coins = 1.5
		end),
		"Data.coins: expected a whole number, got 1.5"
	)
	Spec.equal(
		broken(function(d)
			d.coins = -1
		end),
		"Data.coins: -1 is below the minimum 0"
	)
	Spec.equal(
		broken(function(d)
			d.name = "far too long"
		end),
		"Data.name: 12 bytes, over the maximum 8"
	)
	Spec.equal(
		broken(function(d)
			d.music = 1
		end),
		"Data.music: expected a boolean, got number"
	)
	Spec.equal(
		broken(function(d)
			d.rank = "iron"
		end),
		'Data.rank: "iron" is not one of the allowed values'
	)
	Spec.equal(
		broken(function(d)
			d.inventory = { { id = "a", level = 101 } }
		end),
		"Data.inventory[1].level: 101 is above the maximum 100"
	)
	Spec.equal(
		broken(function(d)
			d.inventory = { {}, {}, {}, {} }
		end),
		"Data.inventory: 4 items, over the maximum 3"
	)
	Spec.equal(
		broken(function(d)
			d.inventory = { [2] = {} }
		end),
		"Data.inventory: expected an array"
	)
	Spec.equal(
		broken(function(d)
			d.pets = { rex = { age = "old" } }
		end),
		"Data.pets.rex.age: expected a number, got string"
	)
	Spec.equal(
		broken(function(d)
			d.pets = { [1] = { age = 1 } }
		end),
		"Data.pets: expected string keys, got a number key"
	)
	Spec.equal(
		broken(function(d)
			d.banned = "yes"
		end),
		"Data.banned: expected a boolean, got string"
	)
	Spec.equal(
		broken(function(d)
			d.stray = 1
		end),
		"Data.stray: not in the schema"
	)
	Spec.equal(
		broken(function(d)
			d.coins = nil
		end),
		"Data.coins: missing"
	)
	Spec.equal(
		broken(function(d)
			d.extra.anything = { 1 }
		end),
		nil,
		"an open record takes any field"
	)
	Spec.equal(
		broken(function(d)
			d.banned = false
		end),
		nil
	)
end)

Spec.test("Schema: reconcile fills what is missing, deep, and changes nothing present", function()
	const data: any = { coins = 99, inventory = { { id = "sword" } }, pets = { rex = {} }, stray = "kept" }
	const result = Schema.reconcile(PROFILE, data)
	Spec.truthy(result == data, "in place")
	Spec.equal(data, {
		coins = 99,
		name = "guest",
		music = true,
		rank = "bronze",
		inventory = { { id = "sword", level = 1 } },
		pets = { rex = { age = 0 } },
		extra = {},
		stray = "kept",
	})
	Spec.equal(Schema.reconcile(S.number({ default = 3 }), nil), 3)
	Spec.equal(
		Schema.reconcile(S.number({ default = 3 }), "wrong"),
		"wrong",
		"check reports it; reconcile never overwrites"
	)
end)

Spec.test("Schema: defaults are fresh copies", function()
	const first, second = Schema.default(PROFILE), Schema.default(PROFILE)
	first.inventory[1] = { id = "x", level = 1 }
	Spec.equal(second.inventory, {})
end)

Spec.test("Schema: a default that breaks its own rules is refused when the schema is built", function()
	Spec.throws(function()
		S.number({ default = -5, min = 0 })
	end, "KeepBlox schema: default: -5 is below the minimum 0")
	Spec.throws(function()
		S.enum({ "a", "b" }, { default = "c" })
	end, 'default: "c" is not one of the allowed values')
	Spec.throws(function()
		S.enum({})
	end, "an enum needs at least one value")
end)

return nil
