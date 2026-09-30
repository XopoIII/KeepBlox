--!strict
--- Differential fuzzing of the save check (PickleFuzzer, arXiv 2605.15084): random and hostile values go
--- through `Validate.check` and through the fake data store's `Encoding`, which models what a data store
--- keeps (checked live). Validate must accept exactly the values the store keeps without loss, at the
--- same size, since the 4 MB limit is enforced from Validate's estimate. The store keeps a mixed table
--- by dropping keys, silently, so a value Validate let through that the store changes is lost data; a
--- value refused that the store keeps is play lost for no reason. Two refusals are by choice: NaN and
--- infinities, which the store keeps but which break every sum they touch; and an array with holes,
--- which the store keeps only when the length operator happens to reach past them, an accident of how
--- the table was built.
const Encoding = require("@fakes/Encoding")
const Prng = require("@fakes/Prng")
const Record = require("@keepblox/Record")
const Repair = require("@keepblox/Repair")
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

-- Whether `a` and `b` hold the same data: the same keys, NaN equal to NaN, buffers by content.
const function same(a: any, b: any): boolean
	if type(a) == "table" and type(b) == "table" then
		for key, item in a do
			if not same(item, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	elseif typeof(a) == "buffer" and typeof(b) == "buffer" then
		return buffer.tostring(a) == buffer.tostring(b)
	elseif a ~= a then
		return b ~= b
	end
	return a == b
end

-- Whether `input` holds NaN or an infinity anywhere.
const function nonFinite(input: any, seen: { [any]: boolean }?): boolean
	if type(input) == "number" then
		return input ~= input or input == math.huge or input == -math.huge
	elseif type(input) == "table" then
		const visited = seen or {}
		if visited[input] then
			return false
		end
		visited[input] = true
		for _, item in input do
			if nonFinite(item, visited) then
				return true
			end
		end
	end
	return false
end

-- Whether `input` holds an array with a hole anywhere (t[1] set, and some index up to #t nil).
const function holes(input: any, seen: { [any]: boolean }?): boolean
	if type(input) ~= "table" then
		return false
	end
	const visited = seen or {}
	if visited[input] then
		return false
	end
	visited[input] = true
	if input[1] ~= nil then
		for index = 1, #input do
			if input[index] == nil then
				return true
			end
		end
	end
	for _, item in input do
		if holes(item, visited) then
			return true
		end
	end
	return false
end

-- The store's verdict: whether it keeps `input` without loss, and at what size.
const function kept(input: any): (boolean, number?)
	const ok, size = pcall(Encoding.size, input)
	if not ok then
		return false, nil
	end
	return same(input, Encoding.stored(input)), size
end

const function describe(input: any): string
	const ok, text = pcall(Encoding.encode, input)
	return if ok then text else `({typeof(input)}, not encodable: {text})`
end

Spec.test("Differential: Validate accepts exactly what the store keeps without loss, at its exact size", function()
	local accepted, refused, byChoice = 0, 0, 0
	for seed = 1, 20 do
		const random = Prng.new(seed)
		for case = 1, 400 do
			const input = value(random, 4)
			const encoded = Validate.check(input, "Data", math.huge)
			const lossless, size = kept(input)
			const where = `seed {seed} case {case}: {describe(input)}`
			if encoded then
				Spec.truthy(lossless, `accepted, but the store changes it: {where}`)
				Spec.equal(encoded.size, size, `size, {where}`)
				accepted += 1
			elseif lossless then
				Spec.truthy(nonFinite(input) or holes(input), `refused, but the store keeps it: {where}`)
				byChoice += 1
			else
				refused += 1
			end
		end
	end
	-- Every kind was really exercised.
	Spec.truthy(accepted > 1000 and refused > 1000 and byChoice > 100, `{accepted}, {refused}, {byChoice}`)
end)

-- Every table and buffer in `value`, by identity.
const function parts(root: any, into: { [any]: boolean }): { [any]: boolean }
	if type(root) == "table" then
		into[root] = true
		for _, item in root do
			parts(item, into)
		end
	elseif type(root) == "buffer" then
		into[root] = true
	end
	return into
end

Spec.test("Differential: a copy of storable data encodes the same and shares nothing with it", function()
	for seed = 1, 10 do
		const random = Prng.new(seed)
		for case = 1, 200 do
			const input = value(random, 4)
			if Validate.check(input, "Data", math.huge) == nil then
				continue
			end
			if type(input) == "table" and random:chance(0.3) then
				-- Frozen data (a session that ended) and a metatable must not come through.
				setmetatable(input, { __index = function() end })
				table.freeze(input :: any)
			end
			const copied = Record.copy(input)
			const where = `seed {seed} case {case}`
			Spec.equal(Encoding.encode(copied), Encoding.encode(input), where)
			const original = parts(input, {})
			for part in parts(copied, {}) do
				Spec.truthy(not original[part], `{where}: the copy shares a {type(part)}`)
			end
			if type(copied) == "table" then
				Spec.truthy(not table.isfrozen(copied) and getmetatable(copied) == nil, where)
			end
		end
	end
end)

Spec.test(
	"Differential: repair leaves storable data alone, and leaves nothing but a table's shape to refuse",
	function()
		local repaired, shape = 0, 0
		for seed = 1, 20 do
			const random = Prng.new(seed)
			for case = 1, 200 do
				const input = value(random, 4)
				const where = `seed {seed} case {case}: {describe(input)}`
				const copied = Record.copy(input)
				const fixes = Repair.run(copied, "Data")
				if Validate.check(input, "Data", math.huge) then
					Spec.equal(fixes, {}, where)
					Spec.equal(Encoding.encode(copied), Encoding.encode(input), where)
					continue
				end
				if type(input) ~= "table" then
					continue -- a bad value at the root is not repaired
				end
				const encoded, problem = Validate.check(copied, "Data", math.huge)
				if encoded then
					Spec.truthy((kept(copied)), `repaired, but the store changes it: {where}`)
					repaired += 1
				else
					Spec.truthy(
						string.find(problem :: string, "key in a table that is not an array", 1, true) ~= nil,
						`{where}: {problem}`
					)
					shape += 1
				end
			end
		end
		Spec.truthy(repaired > 300 and shape > 50, `repaired {repaired}, left for their shape {shape}`)
	end
)

return nil
