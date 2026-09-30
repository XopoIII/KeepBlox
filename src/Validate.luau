--!strict
--!native
--- Checks a value before it is written, and encodes it.
---
--- A data store rejects the whole write for one value it cannot encode: one broken string would fail
--- every save of the session and lose all of it (the "poison" scenario). Other shapes it changes without
--- a word (measured live, 2026-09-30): `{1, 2, x = 3}` is stored as `{1, 2}`, keys past a hole are
--- dropped, number keys of a dictionary become strings; and it keeps NaN, which breaks every sum. So
--- everything is checked here first, and a refusal names the exact path: `Data.inventory[12].name:
--- string is not valid UTF-8`. The last good save stays; nothing is written.
---
--- Refused (per https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching):
--- - NaN and infinities;
--- - strings and keys that are not valid UTF-8;
--- - tables that are neither an array (keys 1..n, no holes) nor a dictionary of string keys;
--- - cycles;
--- - functions, threads, userdata, Instances and other engine types.
---
--- The encoding serves to spot unchanged data and skip the write, so it is built for speed. It runs on
--- every renewal (bench/Run.luau holds its budget), and it is compiled natively. Dictionary keys come
--- in iteration order, which is stable for a table that did not change; a reordered but equal table at
--- worst costs one extra write. `size` estimates the stored JSON length the 4 MB limit applies to.
const Services = require("./Services")

export type Encoded = {
	--> Equal texts mean equal data.
	text: string,
	--> The estimated stored size in bytes (JSON; a buffer as its base64 text).
	size: number,
}

-- The most CPU time one check spends before it lets a frame pass.
const SLICE_SECONDS = 0.002

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

-- Parts joined into one chunk at a time (see State.chunks).
const CHUNK = 4096

-- How many values are checked between two calls of `pause`.
const PAUSE_EVERY = 512

-- The wrapper Roblox stores a buffer in, around its base64 text.
const BUFFER_WRAPPER = #'{"m":null,"t":"buffer","base64":""}'

const function escape(char: string): string
	return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
end

const function encodeString(value: string): string
	if string.find(value, '[%c"\\]') == nil then
		return '"' .. value .. '"'
	end
	return '"' .. string.gsub(value, '[%c"\\]', escape) .. '"'
end

const function encodeNumber(value: number): string
	if value == math.floor(value) and value > -2 ^ 53 and value < 2 ^ 53 then
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

type State = {
	parts: { string },
	count: number,
	--> Parts already joined, a chunk at a time, so the text is built inside the sliced walk and no
	--> frame pays for joining a large profile's text at the end.
	chunks: { string },
	size: number,
	--> The keys down to the value being checked; `depth` of them are current.
	path: { string | number },
	depth: number,
	open: { [any]: boolean },
	root: string,
	--> Values left before the next `pause` call.
	untilPause: number,
	pause: (() -> ())?,
}

-- Throws "<path>: <reason>"; the path is built only here, on the way out.
const function refuse(state: State, reason: string): never
	local text = state.root
	for index = 1, state.depth do
		const key = state.path[index]
		text ..= if type(key) == "number" then `[{key}]` else `.{key}`
	end
	error(`{text}: {reason}`, 0)
end

const function walk(state: State, value: any)
	const parts = state.parts
	if state.count >= CHUNK then
		table.insert(state.chunks, table.concat(parts, ",", 1, state.count))
		state.count = 0
	end
	if state.pause then
		state.untilPause -= 1
		if state.untilPause <= 0 then
			state.untilPause = PAUSE_EVERY
			state.pause()
		end
	end
	const kind = type(value)
	if kind == "string" then
		if utf8.len(value) == nil then
			refuse(state, "string is not valid UTF-8")
		end
		const text = encodeString(value)
		state.count += 1
		parts[state.count] = text
		state.size += #text
	elseif kind == "number" then
		if value ~= value then
			refuse(state, "NaN cannot be stored")
		elseif value == math.huge or value == -math.huge then
			refuse(state, "infinity cannot be stored")
		end
		const text = encodeNumber(value)
		state.count += 1
		parts[state.count] = text
		state.size += #text
	elseif kind == "boolean" then
		state.count += 1
		parts[state.count] = if value then "true" else "false"
		state.size += if value then 4 else 5
	elseif kind == "table" then
		if state.open[value] then
			refuse(state, "table contains itself (a cycle)")
		end
		state.open[value] = true
		const depth = state.depth + 1
		state.depth = depth
		const length = #value
		local count = 0
		for _ in value do
			count += 1
		end
		if count == length then
			state.count += 1
			parts[state.count] = "["
			for index = 1, length do
				state.path[depth] = index
				walk(state, value[index])
			end
			state.count += 1
			parts[state.count] = "]"
			-- Two brackets and a comma between items.
			state.size += if length == 0 then 2 else 1 + length
		else
			state.count += 1
			parts[state.count] = "{"
			for key, item in value do
				if type(key) ~= "string" then
					state.path[depth] = tostring(key)
					refuse(state, `{type(key)} key in a table that is not an array`)
				end
				state.path[depth] = key
				if utf8.len(key) == nil then
					state.depth = depth - 1
					refuse(state, "a key is not valid UTF-8")
				end
				const name = encodeString(key)
				state.count += 1
				parts[state.count] = name
				state.size += #name + 2
				walk(state, item)
			end
			state.count += 1
			parts[state.count] = "}"
			state.size += 1
		end
		state.depth = depth - 1
		state.open[value] = nil
	elseif typeof(value) == "buffer" then
		-- The text carries the bytes; the size counts the base64 form Roblox stores.
		state.count += 1
		parts[state.count] = "buffer:" .. buffer.tostring(value)
		state.size += BUFFER_WRAPPER + 4 * math.ceil(buffer.len(value) / 3)
	else
		refuse(state, `{typeof(value)} cannot be stored`)
	end
end

-- Only for a refusal: follows the biggest field down while it holds most of its parent's size, so
-- the error says what grew (" (most of it: Data.log, 4100000 bytes)").
const function largest(value: any, root: string, size: number): string
	local path = root
	local current = value
	local currentSize = size
	for _ = 1, 8 do
		if type(current) ~= "table" then
			break
		end
		local bestKey: any = nil
		local bestSize = 0
		for key, item in current do
			const encoded = Validate.check(item, "", math.huge)
			const itemSize = if encoded then encoded.size else 0
			if itemSize > bestSize then
				bestKey, bestSize = key, itemSize
			end
		end
		if bestKey == nil or bestSize * 2 < currentSize then
			break
		end
		path ..= if type(bestKey) == "number" then `[{bestKey}]` else `.{bestKey}`
		current, currentSize = current[bestKey], bestSize
	end
	return if path == root then "" else ` (most of it: {path}, {currentSize} bytes)`
end

--> A `pause` for `check` that lets a frame pass after every `SLICE_SECONDS` of CPU time, so a large
--> profile is checked over several frames and never stalls one.
function Validate.slicer(clock: Services.Clock): () -> ()
	local started = os.clock()
	return function()
		if os.clock() - started >= SLICE_SECONDS then
			clock.wait()
			started = os.clock()
		end
	end
end

--> Checks `value` and encodes it; `root` names it in errors ("Data"). Returns the encoding, or nil and
--> the reason, with the path of the first bad value. Refuses anything over `limit` bytes. `pause`, if
--> given, is called every few hundred values: a caller that yields there spreads the work over frames.
--> The value must then not change meanwhile, so check a copy.
function Validate.check(value: any, root: string, limit: number?, pause: (() -> ())?): (Encoded?, string?)
	const state: State = {
		parts = {},
		count = 0,
		chunks = {},
		size = 0,
		path = {},
		depth = 0,
		open = {},
		root = root,
		untilPause = PAUSE_EVERY,
		pause = pause,
	}
	const ok, problem = pcall(walk, state, value)
	if not ok then
		return nil, tostring(problem)
	end
	const cap = limit or Validate.LIMIT
	if state.size > cap then
		return nil, `{root}: about {state.size} bytes, over the {cap} byte limit{largest(value, root, state.size)}`
	end
	const chunks = state.chunks
	if state.count > 0 then
		table.insert(chunks, table.concat(state.parts, ",", 1, state.count))
	end
	return { text = table.concat(chunks, ","), size = state.size }, nil
end

return Validate
