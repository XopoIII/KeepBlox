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
--- Assumed until the live check (docs are silent, so the fake is strict rather than lenient):
--- - NaN and infinities are refused ("don't store inf/-inf/nan", with no stated behaviour);
--- - mixed tables, and dictionaries with non-string keys, are refused;
--- - numbers print in the shortest form that reads back exactly;
--- - a buffer costs its base64 text plus the `{"m":null,"t":"buffer","base64":""}` wrapper.
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

-- Returns the length of `table` as an array, or nil when it is not one (holes, or other keys).
const function arrayLength(value: { [any]: any }): number?
	local count = 0
	for _ in value do
		count += 1
	end
	const length = #value
	if count == length then
		for index = 1, length do
			if value[index] == nil then
				return nil
			end
		end
		return length
	end
	return nil
end

const function encodeValue(value: any, path: string, parts: { string }, open: { [any]: boolean })
	const kind = typeof(value)
	if kind == "nil" then
		table.insert(parts, "null")
	elseif kind == "boolean" then
		table.insert(parts, if value then "true" else "false")
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error(Errors.unmodelled(`storing the number {value} (at {path})`), 0)
		end
		table.insert(parts, encodeNumber(value))
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
		const length = arrayLength(value)
		if length and (length > 0 or next(value) == nil) then
			table.insert(parts, "[")
			for index = 1, length do
				if index > 1 then
					table.insert(parts, ",")
				end
				encodeValue(value[index], `{path}[{index}]`, parts, open)
			end
			table.insert(parts, "]")
		else
			-- Sorted, so the same table always encodes to the same text.
			const keys: { string } = {}
			for key in value do
				if type(key) ~= "string" then
					error(Errors.unmodelled(`a table with a {type(key)} key beside other keys (at {path})`), 0)
				end
				table.insert(keys, key)
			end
			table.sort(keys)
			table.insert(parts, "{")
			for index, key in keys do
				if index > 1 then
					table.insert(parts, ",")
				end
				if utf8.len(key) == nil then
					error(Errors.cantStore(`a key that is not valid UTF-8 (at {path})`), 0)
				end
				table.insert(parts, encodeString(key))
				table.insert(parts, ":")
				encodeValue(value[key], `{path}.{key}`, parts, open)
			end
			table.insert(parts, "}")
		end
		open[value] = nil
	else
		error(Errors.cantStore(`a {kind} (at {path})`), 0)
	end
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
