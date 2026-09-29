--!strict
--- Checks a value before it is written, and encodes it.
---
--- A data store rejects the whole write for one bad value. One stray NaN or broken string would
--- otherwise fail every save of the session and lose all of it (the "poison" scenario). So everything
--- is checked here first, and a refusal names the exact path: `Data.inventory[12].name: string is not
--- valid UTF-8`. The last good save stays; nothing is written.
---
--- Refused (per https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching):
--- - NaN and infinities;
--- - strings and keys that are not valid UTF-8;
--- - tables that are neither an array (keys 1..n, no holes) nor a dictionary of string keys;
--- - cycles;
--- - functions, threads, userdata, Instances and other engine types.
---
--- The encoding is canonical (dictionary keys sorted), so two encodings are equal exactly when the data
--- is. It serves to spot unchanged data and skip the write. `size` estimates the stored JSON length the
--- 4 MB limit applies to.

export type Encoded = {
	--> The canonical text: equal texts mean equal data.
	text: string,
	--> The estimated stored size in bytes (JSON; a buffer as its base64 text).
	size: number,
}

const Validate = {}

--> The data store's value limit, in bytes of JSON.
Validate.LIMIT = 4_194_304

const ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

-- The wrapper Roblox stores a buffer in, around its base64 text.
const BUFFER_WRAPPER = #'{"m":null,"t":"buffer","base64":""}'

const function encodeNumber(value: number): string
	if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end
	for digits = 14, 17 do
		const text = string.format(`%.{digits}g`, value)
		if tonumber(text) == value then
			return text
		end
	end
	return string.format("%.17g", value)
end

const function encodeString(value: string): string
	return '"'
		.. string.gsub(value, '[%c"\\]', function(char: string): string
			return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
		end)
		.. '"'
end

type State = {
	parts: { string },
	size: number,
	path: { string | number },
	open: { [any]: boolean },
}

const function where(state: State, root: string): string
	local text = root
	for _, key in state.path do
		text ..= if type(key) == "number" then `[{key}]` else `.{key}`
	end
	return text
end

-- Throws "<path>: <reason>" at the level of the public call.
const function refuse(state: State, root: string, reason: string): never
	error(`{where(state, root)}: {reason}`, 0)
end

const function emit(state: State, text: string, size: number?)
	table.insert(state.parts, text)
	state.size += size or #text
end

const function walk(state: State, root: string, value: any)
	const kind = typeof(value)
	if kind == "boolean" then
		emit(state, if value then "true" else "false")
	elseif kind == "number" then
		if value ~= value then
			refuse(state, root, "NaN cannot be stored")
		elseif value == math.huge or value == -math.huge then
			refuse(state, root, "infinity cannot be stored")
		end
		emit(state, encodeNumber(value))
	elseif kind == "string" then
		if utf8.len(value) == nil then
			refuse(state, root, "string is not valid UTF-8")
		end
		emit(state, encodeString(value))
	elseif kind == "buffer" then
		-- The canonical text carries the bytes; the size counts the base64 form Roblox stores.
		emit(state, `buffer:{buffer.tostring(value)}`, BUFFER_WRAPPER + 4 * math.ceil(buffer.len(value) / 3))
	elseif kind == "table" then
		if state.open[value] then
			refuse(state, root, "table contains itself (a cycle)")
		end
		state.open[value] = true
		local count = 0
		for _ in value do
			count += 1
		end
		const length = #value
		if count == length then
			emit(state, "[")
			for index = 1, length do
				const item = value[index]
				table.insert(state.path, index)
				if item == nil then
					refuse(state, root, "array has a hole")
				end
				if index > 1 then
					emit(state, ",")
				end
				walk(state, root, item)
				table.remove(state.path)
			end
			emit(state, "]")
		else
			const keys: { string } = {}
			for key in value do
				if type(key) ~= "string" then
					table.insert(state.path, tostring(key))
					refuse(state, root, `{type(key)} key in a table that is not an array`)
				elseif utf8.len(key) == nil then
					refuse(state, root, "a key is not valid UTF-8")
				end
				table.insert(keys, key)
			end
			table.sort(keys)
			emit(state, "{")
			for index, key in keys do
				if index > 1 then
					emit(state, ",")
				end
				emit(state, encodeString(key))
				emit(state, ":")
				table.insert(state.path, key)
				walk(state, root, value[key])
				table.remove(state.path)
			end
			emit(state, "}")
		end
		state.open[value] = nil
	else
		refuse(state, root, `{kind} cannot be stored`)
	end
end

--> Checks `value` and encodes it; `root` names it in errors ("Data"). Returns the encoding, or nil and
--> the reason, with the path of the first bad value. Refuses anything over `limit` bytes.
function Validate.check(value: any, root: string, limit: number?): (Encoded?, string?)
	const state: State = { parts = {}, size = 0, path = {}, open = {} }
	const ok, problem = pcall(walk, state, root, value)
	if not ok then
		return nil, tostring(problem)
	end
	const cap = limit or Validate.LIMIT
	if state.size > cap then
		return nil, `{root}: about {state.size} bytes, over the {cap} byte limit`
	end
	return { text = table.concat(state.parts), size = state.size }, nil
end

return Validate
