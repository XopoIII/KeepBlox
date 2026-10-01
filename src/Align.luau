--!strict
--!native
--- The gaps between two lists: what `Delta` replaces to turn one into the other, in as few items as it
--- can. The longest run of items both lists keep in order stays, and each gap around it is one edit.
---
--- Short middles are aligned by the table of every pair (`table`). Long ones are searched by how many
--- items differ (Myers, "An O(ND) Difference Algorithm", 1986): a long list with a few items taken out
--- or put in costs a few passes over it, not the product of the lengths. A long middle that differs in
--- many places is replaced whole.

type Edit = { k: { string | number }, v: any, a: number?, n: number? }

const Align = {}

const function same(a: any, b: any): boolean
	if a == b then
		return true
	elseif type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

--> Whether two storable values are equal, tables by their contents.
Align.same = same

--> The most items the middles of two lists may multiply to for them to be aligned by the table.
Align.LIMIT = 4096

-- The search for a long middle gives up past this many differing items, or this many comparisons.
const MOST_DIFFERENT = 32
const MOST_COMPARED = 8192

-- The gaps by the table of every pair. Positions are those in `now`: the edits apply in order, and all
-- before a gap is `now`'s then.
const function byTable(
	base: { any },
	now: { any },
	head: number,
	tail: number,
	path: { string | number },
	edits: { Edit }
)
	const m, n = #base - head - tail, #now - head - tail
	const width = n + 1
	-- kept[i * width + j + 1]: the most items `base` from head + i + 1 and `now` from head + j + 1 share.
	const kept = table.create((m + 1) * width, 0)
	for i = m - 1, 0, -1 do
		for j = n - 1, 0, -1 do
			kept[i * width + j + 1] = if same(base[head + i + 1], now[head + j + 1])
				then kept[(i + 1) * width + j + 2] + 1
				else math.max(kept[(i + 1) * width + j + 1], kept[i * width + j + 2])
		end
	end
	local i, j = 0, 0
	while i < m or j < n do
		if i < m and j < n and kept[i * width + j + 1] > 0 and same(base[head + i + 1], now[head + j + 1]) then
			i, j = i + 1, j + 1
			continue
		end
		const fromI, fromJ = i, j
		repeat
			if j >= n or (i < m and kept[(i + 1) * width + j + 1] >= kept[i * width + j + 2]) then
				i += 1
			else
				j += 1
			end
		until (i >= m and j >= n)
			or (i < m and j < n and kept[i * width + j + 1] > 0 and same(base[head + i + 1], now[head + j + 1]))
		const items = table.move(now, head + fromJ + 1, head + j, 1, {})
		table.insert(edits, { k = path, a = head + fromJ + 1, n = i - fromI, v = if #items > 0 then items else nil })
	end
end

-- For each item of `base`'s middle, the position in `now`'s middle of the item it stays as (0: it goes),
-- found by how many items differ; nil when the lists differ in too many places.
const function partners(base: { any }, now: { any }, head: number, m: number, n: number): { number }?
	const most = math.min(m + n, MOST_DIFFERENT)
	const offset = most + 2
	-- reach[k + offset]: how far into `base` the best path on diagonal k (x - y) has come.
	const reach = table.create(2 * most + 3, 0)
	const history: { { number } } = {}
	local compared = 0
	for d = 0, most do
		history[d + 1] = table.clone(reach)
		for k = -d, d, 2 do
			local x = if k == -d or (k ~= d and reach[k - 1 + offset] < reach[k + 1 + offset])
				then reach[k + 1 + offset]
				else reach[k - 1 + offset] + 1
			local y = x - k
			while x < m and y < n and same(base[head + x + 1], now[head + y + 1]) do
				x, y = x + 1, y + 1
				compared += 1
			end
			compared += 1
			reach[k + offset] = x
			if x >= m and y >= n then
				-- Back along the path: every diagonal step is an item kept.
				const partner = table.create(m, 0)
				for back = d, 1, -1 do
					const before = history[back + 1]
					const diagonal = x - y
					const from = if diagonal == -back
							or (diagonal ~= back and before[diagonal - 1 + offset] < before[diagonal + 1 + offset])
						then diagonal + 1
						else diagonal - 1
					const fromX = before[from + offset]
					const fromY = fromX - from
					while x > fromX and y > fromY do
						partner[x] = y
						x, y = x - 1, y - 1
					end
					x, y = fromX, fromY
				end
				while x > 0 and y > 0 do
					partner[x] = y
					x, y = x - 1, y - 1
				end
				return partner
			end
		end
		if compared > MOST_COMPARED then
			return nil
		end
	end
	return nil
end

--> Replaces what lies between `head` items and `tail` items of `base` with what lies there in `now`:
--> appends the edits to `edits`. A long middle that differs in too many places is replaced in one edit
--> when `whole`; otherwise nothing is appended, and false returned.
function Align.gaps(
	base: { any },
	now: { any },
	head: number,
	tail: number,
	path: { string | number },
	edits: { Edit },
	whole: boolean
): boolean
	const m, n = #base - head - tail, #now - head - tail
	if m * n <= Align.LIMIT then
		byTable(base, now, head, tail, path, edits)
		return true
	end
	const partner = partners(base, now, head, m, n)
	if not partner then
		if whole then
			const items = table.move(now, head + 1, head + n, 1, {})
			table.insert(edits, { k = path, a = head + 1, n = m, v = if #items > 0 then items else nil })
		end
		return whole
	end
	local i, j = 0, 0
	while i < m or j < n do
		if i < m and partner[i + 1] == j + 1 then
			i, j = i + 1, j + 1
			continue
		end
		const fromI, fromJ = i, j
		while i < m and partner[i + 1] == 0 do
			i += 1
		end
		j = if i < m then partner[i + 1] - 1 else n
		const items = table.move(now, head + fromJ + 1, head + j, 1, {})
		table.insert(edits, { k = path, a = head + fromJ + 1, n = i - fromI, v = if #items > 0 then items else nil })
	end
	return true
end

return Align
