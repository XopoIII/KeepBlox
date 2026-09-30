--!strict
--- Repairs data a data store would refuse, so one bad value does not cost the play around it.
---
--- Validate refuses the whole write for one bad value, and until the game removes it the session
--- stores nothing: every step played meanwhile is lost at the next crash or hop (the "poison"
--- scenario). Here the session's private copy is repaired, value by value, and that is stored:
--- - a string that is not valid UTF-8 keeps its text, each bad byte replaced by U+FFFD;
--- - NaN and infinities, and values of types no data store holds (functions, Instances, threads), are
---   left out: a dictionary loses the key, an array the item;
--- - a key that is not valid UTF-8, or neither a string nor a number, is left out with its value;
--- - a table that contains itself loses the reference that closes the loop.
--- The game's own data is never touched, and every repair is reported with its path. A table's shape
--- (a mixed or sparse table) and the size limit are not repaired: then nothing is stored, as before,
--- and the last good snapshot stays.

const Repair = {}

const REPLACEMENT = utf8.char(0xFFFD)

-- `text` with every byte that does not start a valid UTF-8 sequence replaced.
const function mend(text: string): string
	const pieces = {}
	local from = 1
	while from <= #text do
		const length, bad = utf8.len(text, from)
		if length ~= nil then
			table.insert(pieces, string.sub(text, from))
			break
		end
		table.insert(pieces, string.sub(text, from, (bad :: number) - 1))
		table.insert(pieces, REPLACEMENT)
		from = (bad :: number) + 1
	end
	return table.concat(pieces)
end

-- Why `value` cannot be stored as it is, or nil when it can (tables are looked into by the caller).
const function fault(value: any): string?
	const kind = type(value)
	if kind == "number" then
		if value ~= value then
			return "NaN cannot be stored"
		elseif value == math.huge or value == -math.huge then
			return "infinity cannot be stored"
		end
		return nil
	elseif kind == "string" or kind == "boolean" or kind == "table" or kind == "buffer" then
		return nil
	end
	return `{typeof(value)} cannot be stored`
end

const function walk(tbl: { [any]: any }, path: string, open: { [any]: boolean }, fixes: { string })
	open[tbl] = true
	local count = 0
	for _ in tbl do
		count += 1
	end
	const isArray = count == #tbl
	const drop: { any } = {}
	for key, value in tbl do
		const at = if type(key) == "number" then `{path}[{key}]` else `{path}.{tostring(key)}`
		const keyKind = type(key)
		if keyKind ~= "string" and keyKind ~= "number" then
			table.insert(fixes, `{at}: a {typeof(key)} key cannot be stored; left out`)
			table.insert(drop, key)
		elseif keyKind == "string" and utf8.len(key) == nil then
			table.insert(fixes, `{path}: a key is not valid UTF-8; left out`)
			table.insert(drop, key)
		elseif type(value) == "string" and utf8.len(value) == nil then
			tbl[key] = mend(value)
			table.insert(fixes, `{at}: string is not valid UTF-8; its bad bytes were replaced`)
		elseif type(value) == "table" and open[value] then
			table.insert(fixes, `{at}: table contains itself (a cycle); left out`)
			table.insert(drop, key)
		elseif type(value) == "table" then
			walk(value, at, open, fixes)
		else
			const problem = fault(value)
			if problem then
				table.insert(fixes, `{at}: {problem}; left out`)
				table.insert(drop, key)
			end
		end
	end
	if isArray then
		-- From the end, so the indices still to remove stay where they were.
		table.sort(drop, function(a: any, b: any): boolean
			return a > b
		end)
		for _, index in drop do
			table.remove(tbl, index)
		end
	else
		for _, key in drop do
			tbl[key] = nil
		end
	end
	open[tbl] = nil
end

--> Repairs `value` in place (a copy the caller owns) and returns what was repaired, each with its path
--> under `root`; empty when nothing needed it. A value that is not a table is not repaired here.
function Repair.run(value: any, root: string): { string }
	const fixes: { string } = {}
	if type(value) == "table" then
		walk(value, root, {}, fixes)
	end
	return fixes
end

return Repair
