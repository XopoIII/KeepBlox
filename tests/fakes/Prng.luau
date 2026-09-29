--!strict
--- A seeded pseudo-random generator: xorshift32 (Marsaglia, 2003).
---
--- The harness replays a failing run from its seed alone, so the generator must give the same
--- sequence on every runtime and every Luau version. It is written here on `bit32` rather than taken
--- from `Random`, whose algorithm is the engine's business and may change under us.
---
--- It decides test schedules, not secrets: statistical quality beyond "well spread" is not needed.

export type Prng = {
	read seed: number,
	--> The next raw value in [1, 2^32 - 1].
	nextU32: (self: Prng) -> number,
	--> An integer in [low, high], both inclusive.
	integer: (self: Prng, low: number, high: number) -> number,
	--> A number in [0, 1).
	number: (self: Prng) -> number,
	--> True with probability `p`; exactly false at 0 and exactly true at 1.
	chance: (self: Prng, p: number) -> boolean,
}

const Prng = {}

--> A generator for `seed`, any integer. Seeds that differ give sequences that differ.
function Prng.new(seed: number): Prng
	assert(seed == math.floor(seed), "Prng seed must be an integer")
	-- xorshift has one fixed point, zero; fold the seed into 32 bits and step off it.
	local state = bit32.band(seed, 0xFFFFFFFF)
	if state == 0 then
		state = 0x9E3779B9
	end

	const function nextU32(_: Prng): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state
	end

	const function integer(self: Prng, low: number, high: number): number
		assert(low == math.floor(low) and high == math.floor(high), "Prng:integer bounds must be integers")
		assert(low <= high, `Prng:integer empty range [{low}, {high}]`)
		return low + self:nextU32() % (high - low + 1)
	end

	const function number(self: Prng): number
		return (self:nextU32() - 1) / 4294967295
	end

	const function chance(self: Prng, p: number): boolean
		if p <= 0 then
			return false
		elseif p >= 1 then
			return true
		end
		return self:number() < p
	end

	const self: Prng = {
		seed = seed,
		nextU32 = nextU32,
		integer = integer,
		number = number,
		chance = chance,
	}
	-- Seeds close together start close together; a few rounds spread them apart.
	for _ = 1, 8 do
		self:nextU32()
	end
	return self
end

return Prng
