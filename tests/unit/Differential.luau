--!strict
--- Differential fuzzing of the save check (PickleFuzzer, arXiv 2605.15084): random and hostile values go
--- through `Validate.check` and through the fake data store's `Encoding`, which models what
--- `HttpService:JSONEncode` stores. They must agree on what can be stored, and on its size, since the
--- 4 MB limit is enforced from Validate's estimate. Any disagreement is a write that fails at the store
--- or a value refused for no reason.
const Encoding = require("@fakes/Encoding")
const Prng = require("@fakes/Prng")
const Spec = require("../Spec")
const Validate = require("@keepblox/Validate")

const STRINGS = {
	"",
	"coins",
	'say "hi"',
	"back\\slash",
	"tab\tline\nfeed",
	string.char(0, 1, 31, 127),
	utf8.char(0xE9),
	utf8.char(0x65E5, 0x672C),
	utf8.char(0x1F600),
	"1",
	"-0",
	-- Not valid UTF-8: a stray byte, an overlong slash, a surrogate half, a cut sequence.
	string.char(255),
	string.char(192, 175),
	string.char(237, 160, 128),
	string.char(226, 130),
}

const NUMBERS = { 0, -0, 1, -1, 7, 2 ^ 31, 2 ^ 53 - 1, 2 ^ 53, -2 ^ 53, 2 ^ 63, 0.1, 1 / 3, -2.5, 1e300, 5e-324, 1e21 }

const function scalar(random: Prng.Prng): any
	const roll = random:integer(1, 20)
	if roll <= 6 then
		return STRINGS[random:integer(1, #STRINGS)]
	elseif roll <= 10 then
		return NUMBERS[random:integer(1, #NUMBERS)]
	elseif roll <= 13 then
		return (random:number() - 0.5) * 10 ^ random:integer(-8, 20)
	elseif roll <= 16 then
		return random:chance(0.5)
	elseif roll == 17 then
		const bytes = buffer.create(random:integer(0, 7))
		for index = 0, buffer.len(bytes) - 1 do
			buffer.writeu8(bytes, index, random:integer(0, 255))
		end
		return bytes
	elseif roll == 18 then
		return if random:chance(0.5) then 0 / 0 else math.huge * (if random:chance(0.5) then 1 else -1)
	end
	return random:integer(-1000, 1000)
end

const function value(random: Prng.Prng, depth: number): any
	if depth <= 0 or random:chance(0.45) then
		return scalar(random)
	end
	const shape = random:integer(1, 20)
	const result: { [any]: any } = {}
	if shape <= 9 then
		for index = 1, random:integer(0, 5) do
			result[index] = value(random, depth - 1)
		end
		if shape == 9 then
			result[random:integer(2, 7)] = nil -- a hole, or none
		end
	elseif shape <= 18 then
		for _ = 1, random:integer(0, 5) do
			result[STRINGS[random:integer(1, #STRINGS)] .. tostring(random:integer(0, 3))] = value(random, depth - 1)
		end
	elseif shape == 19 then
		result[1] = scalar(random)
		result.name = scalar(random) -- a mixed table
	else
		result.self = result -- a cycle
	end
	return result
end

const function describe(input: any): string
	const ok, text = pcall(Encoding.encode, input)
	return if ok then text else `({typeof(input)}, not encodable: {text})`
end

Spec.test("Differential: Validate and the store agree on what can be stored, and its exact size", function()
	local accepted, refused = 0, 0
	for seed = 1, 20 do
		const random = Prng.new(seed)
		for case = 1, 400 do
			const input = value(random, 4)
			const encoded = Validate.check(input, "Data", math.huge)
			const ok, size = pcall(Encoding.size, input)
			const where = `seed {seed} case {case}: {describe(input)}`
			Spec.equal(encoded ~= nil, ok, `accepted by one side only, {where}`)
			if encoded and ok then
				Spec.equal(encoded.size, size, `size, {where}`)
				accepted += 1
			else
				refused += 1
			end
		end
	end
	-- Both kinds were really exercised.
	Spec.truthy(accepted > 1000 and refused > 1000, `accepted {accepted}, refused {refused}`)
end)

return nil
