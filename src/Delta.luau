--!strict
--!native
--- The changes between two storable values, as a list of edits, and a fingerprint that names a value
--- the same way on every server.
---
--- A crash snapshot of a large profile (see Snapshots) carries only what changed since the data was last
--- stored: a player with fifty things on a base changes coins and counters from beat to beat, not the
--- things. The server taking over applies the edits to the record it claimed, but only when the record's
--- fingerprint is the one the edits were made against; otherwise the edits are ignored, and the stored
--- data is used.
---
--- An edit is one of:
--- - `{ k = path, v = value }`: the value at `path` (keys from the root) becomes `v`, or is removed when
---   there is no `v`. An empty path replaces the whole value.
--- - `{ k = path, a = at, n = count, v = items }`: in the array at `path`, `count` items from index `at`
---   are replaced by `items` (none when there is no `v`). An item taken out of the middle of a list
---   moves the items after it; this says so in one edit instead of one for each item moved.
--- Values are storable (see Validate): no NaN, no cycles, arrays without holes, dictionaries of string
--- keys.

export type Edit = { k: { string | number }, v: any, a: number?, n: number? }

const Align = require("./Align")

const Delta = {}

const same = Align.same

const function within(path: { string | number }, key: string | number): { string | number }
	const at = table.clone(path)
	table.insert(at, key)
	return at
end

local walk: (base: any, now: any, path: { string | number }, edits: { Edit }) -> ()

-- The edit for one key whose value went from `old` to `value`.
const function step(old: any, value: any, path: { string | number }, key: string | number, edits: { Edit })
	if old == value then
		return
	elseif type(old) == "table" and type(value) == "table" then
		walk(old, value, within(path, key), edits)
	elseif not same(old, value) then
		table.insert(edits, { k = within(path, key), v = value })
	end
end

-- Two arrays: the items both begin and end with are kept. What lies between is edited item by item when
-- it kept its length and its items did not move; otherwise it is aligned (see `align`).
const function lists(base: { any }, now: { any }, path: { string | number }, edits: { Edit })
	const was, is = #base, #now
	local head = 0
	while head < was and head < is and same(base[head + 1], now[head + 1]) do
		head += 1
	end
	local tail = 0
	while tail < was - head and tail < is - head and same(base[was - tail], now[is - tail]) do
		tail += 1
	end
	if was == is then
		-- Items moved when the middle starts one item later in either list.
		const middle = is - head - tail
		const moved = middle > 1 and (same(base[head + 2], now[head + 1]) or same(base[head + 1], now[head + 2]))
		-- A long middle that differs in too many places to align is edited item by item too.
		if not moved or not Align.gaps(base, now, head, tail, path, edits, false) then
			for index = head + 1, is - tail do
				step(base[index], now[index], path, index, edits)
			end
		end
		return
	end
	Align.gaps(base, now, head, tail, path, edits, true)
end

function walk(base: any, now: any, path: { string | number }, edits: { Edit })
	if #base > 0 and #now > 0 then
		lists(base, now, path, edits)
		return
	end
	for key, value in now do
		step(base[key], value, path, key, edits)
	end
	for key in base do
		if now[key] == nil then
			table.insert(edits, { k = within(path, key) } :: Edit)
		end
	end
end

--> The edits that turn `base` into `now`; empty when they are equal. `now`'s tables are shared, not
--> copied: diff a copy that no one changes.
function Delta.diff(base: any, now: any): { Edit }
	const edits: { Edit } = {}
	if type(base) == "table" and type(now) == "table" then
		walk(base, now, {}, edits)
	elseif not same(base, now) then
		table.insert(edits, { k = {}, v = now })
	end
	return edits
end

-- `list` with `count` items from `at` replaced by `items`; false when it is not a list that long.
const function splice(list: any, at: any, count: any, items: any): boolean
	const size = if type(list) == "table" then #list else -1
	if
		type(at) ~= "number"
		or type(count) ~= "number"
		or at < 1
		or count < 0
		or at + count - 1 > size
		or (items ~= nil and type(items) ~= "table")
	then
		return false
	end
	const added = if items then #items else 0
	table.move(list, at + count, size, at + added)
	for index = size + added - count + 1, size do
		list[index] = nil
	end
	if items then
		table.move(items, 1, added, at, list)
	end
	return true
end

--> `base` with `edits` applied; `base` itself is changed. Nil when an edit does not fit `base`: a path
--> that does not lead through its tables, or a replacement past the end of a list.
function Delta.apply(base: any, edits: { Edit }): any
	local root = base
	for _, edit in edits do
		const path = edit.k
		local at = root
		for index = 1, #path - (if edit.a == nil then 1 else 0) do
			at = if type(at) == "table" then at[path[index]] else nil
		end
		if edit.a ~= nil then
			if not splice(at, edit.a, edit.n, edit.v) then
				return nil
			end
		elseif #path == 0 then
			root = edit.v
		elseif type(at) ~= "table" then
			return nil
		else
			at[path[#path]] = edit.v
		end
	end
	return root
end

-- Keys in one order on every server: numbers before strings, each in ascending order.
const function before(a: any, b: any): boolean
	const ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta == "number"
	end
	return a < b
end

const function canonical(value: any, parts: { string })
	const kind = type(value)
	if kind == "table" then
		const keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, before)
		table.insert(parts, "{")
		for _, key in keys do
			canonical(key, parts)
			canonical(value[key], parts)
		end
		table.insert(parts, "}")
	elseif kind == "string" then
		table.insert(parts, `s{#value}:{value}`)
	elseif kind == "number" then
		table.insert(parts, if value == 0 then "n0" else string.format("n%.14g", value))
	else
		table.insert(parts, tostring(value))
	end
end

--> A name for `value` that is the same on every server for equal values, whatever order their tables
--> were built in: two hashes of its canonical text, 16 hex digits.
function Delta.fingerprint(value: any): string
	const parts = {}
	canonical(value, parts)
	const text = table.concat(parts)
	const bytes = buffer.create(#text + 3)
	buffer.writestring(bytes, 0, text)
	local a, b = #text, 0x9E3779B9
	for offset = 0, #text - 1, 4 do
		const word = buffer.readu32(bytes, offset)
		a = (a * 31 + word) % 0x100000000
		b = (bit32.bxor(b, word) * 1000003) % 0x100000000
	end
	return string.format("%08x%08x", a, b)
end

return Delta
