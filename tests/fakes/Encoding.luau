--!strict
--- What a data store accepts, what it costs against the size limit, and a private copy of it.
---
--- Roblox stores a value as its JSON text and measures it the same way: "the serialized length of the
--- value can't exceed ... To check the serialized length of the data, use JSONEncode()"
--- (https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits). So `encode`
--- mimics `HttpService:JSONEncode`, and the size is the byte length of its output.
---
--- Accepted (https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching):
--- nil, booleans, finite numbers, valid UTF-8 strings, tables, buffers. A table is an array (keys 1..n,
--- no holes) or a dictionary with string keys.
---
--- Checked live (Studio, 2026-09-30; the docs are silent), and modelled here:
--- - NaN and infinities are stored, as `{"m":null,"t":"numeric","v":"nan"|"inf"|"-inf"}`, and read back;
--- - a table with `t[1]` is written as the array `1..#t`: holes become null, and every other key is
---   dropped without an error (`{1, 2, x = 3}` reads back as `{1, 2}`);
--- - any other table is a dictionary: a number key becomes the text of the integer it truncates to,
---   clamped to 64 bits (`[2.5]` is stored as `"2"`); a boolean key is refused;
--- - numbers print in the shortest form that reads back exactly;
--- - a buffer costs its base64 text plus the `{"m":null,"t":"buffer","base64":""}` wrapper.
--- Still refused as unmodelled: other key types, and two keys that become the same text.
--- If LuneBlox gains an engine-exact `JSONEncode`, this file should defer to it: that is a LuneBlox task.
const Errors = require("./Errors")

const Encoding = {}

const ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

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
	const escaped = string.gsub(value, '[%c"\\]', function(char: string): string
		return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
	end)
	return `"{escaped}"`
end

const NON_FINITE: { [string]: string } = { nan = "nan", inf = "inf", ["-inf"] = "-inf" }

const function nonFinite(value: number): string?
	return if value ~= value
		then NON_FINITE.nan
		elseif value == math.huge then NON_FINITE.inf
		elseif value == -math.huge then NON_FINITE["-inf"]
		else nil
end

-- The text a number key is stored under: the integer it truncates to, clamped to 64 bits.
const function numberKey(key: number): string
	if key >= 2 ^ 63 then
		return "9223372036854775807"
	elseif key < -2 ^ 63 then
		return "-9223372036854775808"
	end
	return string.format("%d", if key >= 0 then math.floor(key) else math.ceil(key))
end

-- A dictionary's keys as stored, sorted (so the same table always encodes to the same text), each with
-- the key it came from.
type StoredKey = { text: string, key: any }

const function dictionaryKeys(value: { [any]: any }, path: string): { StoredKey }
	const keys: { StoredKey } = {}
	const seen: { [string]: boolean } = {}
	for key in value do
		local text: string
		if type(key) == "string" then
			if utf8.len(key) == nil then
				error(Errors.cantStore(`a key that is not valid UTF-8 (at {path})`), 0)
			end
			text = key
		elseif type(key) == "number" then
			text = numberKey(key)
		elseif type(key) == "boolean" then
			error(Errors.invalidKeyType(), 0)
		else
			error(Errors.unmodelled(`a table with a {typeof(key)} key (at {path})`), 0)
		end
		if seen[text] then
			error(Errors.unmodelled(`two keys stored as "{text}" (at {path})`), 0)
		end
		seen[text] = true
		table.insert(keys, { text = text, key = key })
	end
	table.sort(keys, function(a: StoredKey, b: StoredKey): boolean
		return a.text < b.text
	end)
	return keys
end

const function encodeValue(value: any, path: string, parts: { string }, open: { [any]: boolean })
	const kind = typeof(value)
	if kind == "nil" then
		table.insert(parts, "null")
	elseif kind == "boolean" then
		table.insert(parts, if value then "true" else "false")
	elseif kind == "number" then
		const special = nonFinite(value)
		table.insert(parts, if special then '{"m":null,"t":"numeric","v":"' .. special .. '"}' else encodeNumber(value))
	elseif kind == "string" then
		if utf8.len(value) == nil then
			error(Errors.cantStore(`a string that is not valid UTF-8 (at {path})`), 0)
		end
		table.insert(parts, encodeString(value))
	elseif kind == "buffer" then
		-- base64 turns every 3 bytes into 4 characters, padded.
		const encoded = 4 * math.ceil(buffer.len(value) / 3)
		table.insert(parts, string.rep("x", BUFFER_WRAPPER + encoded))
	elseif kind == "table" then
		if open[value] then
			error(Errors.cantStore(`a cyclic table (at {path})`), 0)
		end
		open[value] = true
		if value[1] ~= nil or next(value) == nil then
			table.insert(parts, "[")
			for index = 1, #value do
				if index > 1 then
					table.insert(parts, ",")
				end
				encodeValue(value[index], `{path}[{index}]`, parts, open)
			end
			table.insert(parts, "]")
		else
			table.insert(parts, "{")
			for index, entry in dictionaryKeys(value, path) do
				if index > 1 then
					table.insert(parts, ",")
				end
				table.insert(parts, encodeString(entry.text))
				table.insert(parts, ":")
				encodeValue(value[entry.key], `{path}.{entry.text}`, parts, open)
			end
			table.insert(parts, "}")
		end
		open[value] = nil
	else
		error(Errors.cantStore(`a {kind} (at {path})`), 0)
	end
end

-- What a read gives back for `value`, which encoded without error.
const function storedValue(value: any): any
	if type(value) == "table" then
		const result = {}
		if value[1] ~= nil then
			for index = 1, #value do
				result[index] = storedValue(value[index])
			end
		else
			for key, item in value do
				result[if type(key) == "number" then numberKey(key) else key] = storedValue(item)
			end
		end
		return result
	elseif typeof(value) == "buffer" then
		const result = buffer.create(buffer.len(value))
		buffer.copy(result, 0, value)
		return result
	end
	return value
end

--> The JSON text Roblox would store for `value`. Throws the engine's error for anything it refuses.
function Encoding.encode(value: any): string
	const parts: { string } = {}
	encodeValue(value, "value", parts, {})
	return table.concat(parts)
end

--> The size `value` counts for against the 4 MB limit, in bytes.
function Encoding.size(value: any): number
	return #Encoding.encode(value)
end

--> What a data store, a memory store or a message holds for `value`: what reading it back gives,
--> sharing nothing with `value`. Throws the engine's error for anything it refuses.
function Encoding.stored(value: any): any
	Encoding.encode(value)
	return storedValue(value)
end

--> A deep copy that shares nothing with `value`: a stored value never aliases the caller's table,
--> and a read never hands out the stored one. Buffers are copied too.
function Encoding.copy(value: any): any
	if type(value) == "table" then
		const result = {}
		for key, item in value do
			result[key] = Encoding.copy(item)
		end
		return result
	elseif typeof(value) == "buffer" then
		const result = buffer.create(buffer.len(value))
		buffer.copy(result, 0, value)
		return result
	end
	return value
end

return Encoding
