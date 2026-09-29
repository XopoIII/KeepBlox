--!strict
const Prng = require("@fakes/Prng")
const Spec = require("../Spec")

const function sequence(seed: number, length: number): { number }
	const random = Prng.new(seed)
	const values = {}
	for index = 1, length do
		values[index] = random:nextU32()
	end
	return values
end

Spec.test("Prng: one seed gives one sequence", function()
	Spec.equal(sequence(42, 50), sequence(42, 50))
end)

Spec.test("Prng: neighbouring seeds diverge from the first value", function()
	const a, b = sequence(1, 8), sequence(2, 8)
	for index = 1, 8 do
		Spec.truthy(a[index] ~= b[index], `value {index} differs`)
	end
end)

Spec.test("Prng: seed 0 is usable and not stuck at zero", function()
	const values = sequence(0, 16)
	for index, value in values do
		Spec.truthy(value > 0 and value <= 0xFFFFFFFF, `value {index} in range`)
	end
	Spec.truthy(values[1] ~= values[2], "it moves")
end)

Spec.test("Prng: integer covers both bounds and nothing outside", function()
	const random = Prng.new(7)
	const seen: { [number]: boolean } = {}
	for _ = 1, 2000 do
		const value = random:integer(-2, 2)
		Spec.truthy(value >= -2 and value <= 2 and value == math.floor(value), `{value} in [-2, 2]`)
		seen[value] = true
	end
	Spec.equal(seen, { [-2] = true, [-1] = true, [0] = true, [1] = true, [2] = true })
	Spec.equal(random:integer(5, 5), 5)
end)

Spec.test("Prng: integer refuses an empty or fractional range", function()
	const random = Prng.new(1)
	Spec.throws(function()
		random:integer(3, 2)
	end, "empty range [3, 2]")
	Spec.throws(function()
		random:integer(0.5, 2)
	end, "bounds must be integers")
	Spec.throws(function()
		Prng.new(1.5)
	end, "seed must be an integer")
end)

Spec.test("Prng: number stays in [0, 1) and chance is exact at its ends", function()
	const random = Prng.new(99)
	local hits = 0
	for _ = 1, 1000 do
		const value = random:number()
		Spec.truthy(value >= 0 and value < 1, `{value} in [0, 1)`)
		Spec.equal(random:chance(0), false)
		Spec.equal(random:chance(1), true)
		if random:chance(0.5) then
			hits += 1
		end
	end
	-- Not a statistics test: only that a half chance is neither never nor always.
	Spec.truthy(hits > 400 and hits < 600, `{hits} of 1000 half chances hit`)
end)

return nil
