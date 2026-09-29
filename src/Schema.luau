--!strict
--- A description of a profile's data: its types, defaults and bounds, nested as deep as the data is.
---
---     const S = KeepBlox.schema
---     const schema = S.record({
---         coins = S.number({ default = 0, min = 0, integer = true }),
---         name = S.string({ default = "", maxLength = 20 }),
---         inventory = S.array(S.record({ id = S.string(), level = S.number({ default = 1, min = 1 }) }), { max = 500 }),
---         settings = S.record({ music = S.boolean({ default = true }) }),
---         pets = S.map(S.record({ kind = S.enum({ "cat", "dog" }, { default = "cat" }) })),
---         banned = S.optional(S.boolean()),
---     })
---
--- The schema gives new profiles their data (its defaults). On load it fills fields a record lacks
--- (`reconcile`). Before every save it checks the data (`check`); a refusal names the path, as
--- Validate does. Records are strict: a field the schema does not name is an error, unless the record
--- is `open`. Defaults are checked against their own bounds when the schema is built.

export type Kind = "number" | "string" | "boolean" | "buffer" | "enum" | "record" | "array" | "map" | "optional" | "any"

export type Node = {
	read kind: Kind,
	read default: any,
	read min: number?,
	read max: number?,
	read integer: boolean?,
	read maxLength: number?,
	read values: { [string]: boolean }?,
	read fields: { [string]: Node }?,
	read open: boolean?,
	read item: Node?,
	read maxItems: number?,
}

type Options = { [string]: any }

const Schema = {}

const function where(path: { string | number }, root: string): string
	local text = root
	for _, key in path do
		text ..= if type(key) == "number" then `[{key}]` else `.{key}`
	end
	return text
end

const function describe(value: any): string
	return if typeof(value) == "table" then "a table" else typeof(value)
end

-- The first problem with `value` under `node`, or nil.
const function problem(node: Node, value: any, path: { string | number }, root: string): string?
	const kind = node.kind
	if kind == "any" then
		return nil
	elseif kind == "optional" then
		return if value == nil then nil else problem(node.item :: Node, value, path, root)
	elseif value == nil then
		return `{where(path, root)}: missing`
	elseif kind == "number" then
		if type(value) ~= "number" then
			return `{where(path, root)}: expected a number, got {describe(value)}`
		elseif node.integer and value ~= math.floor(value) then
			return `{where(path, root)}: expected a whole number, got {value}`
		elseif node.min and value < node.min then
			return `{where(path, root)}: {value} is below the minimum {node.min}`
		elseif node.max and value > node.max then
			return `{where(path, root)}: {value} is above the maximum {node.max}`
		end
	elseif kind == "string" or kind == "enum" then
		if type(value) ~= "string" then
			return `{where(path, root)}: expected a string, got {describe(value)}`
		elseif node.maxLength and #value > node.maxLength then
			return `{where(path, root)}: {#value} bytes, over the maximum {node.maxLength}`
		elseif node.values and not node.values[value] then
			return `{where(path, root)}: "{value}" is not one of the allowed values`
		end
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return `{where(path, root)}: expected a boolean, got {describe(value)}`
		end
	elseif kind == "buffer" then
		if typeof(value) ~= "buffer" then
			return `{where(path, root)}: expected a buffer, got {describe(value)}`
		elseif node.maxLength and buffer.len(value) > node.maxLength then
			return `{where(path, root)}: {buffer.len(value)} bytes, over the maximum {node.maxLength}`
		end
	elseif type(value) ~= "table" then
		return `{where(path, root)}: expected a table, got {describe(value)}`
	elseif kind == "record" then
		const fields = node.fields :: { [string]: Node }
		for name, field in fields do
			table.insert(path, name)
			const found = problem(field, value[name], path, root)
			table.remove(path)
			if found then
				return found
			end
		end
		if not node.open then
			for name in value do
				if type(name) ~= "string" or fields[name] == nil then
					table.insert(path, tostring(name))
					const text = `{where(path, root)}: not in the schema`
					table.remove(path)
					return text
				end
			end
		end
	elseif kind == "array" then
		local count = 0
		for _ in value do
			count += 1
		end
		if count ~= #value then
			return `{where(path, root)}: expected an array`
		elseif node.maxItems and count > node.maxItems then
			return `{where(path, root)}: {count} items, over the maximum {node.maxItems}`
		end
		for index, item in value do
			table.insert(path, index)
			const found = problem(node.item :: Node, item, path, root)
			table.remove(path)
			if found then
				return found
			end
		end
	elseif kind == "map" then
		local count = 0
		for key, item in value do
			count += 1
			if type(key) ~= "string" then
				return `{where(path, root)}: expected string keys, got a {type(key)} key`
			end
			table.insert(path, key)
			const found = problem(node.item :: Node, item, path, root)
			table.remove(path)
			if found then
				return found
			end
		end
		if node.maxItems and count > node.maxItems then
			return `{where(path, root)}: {count} entries, over the maximum {node.maxItems}`
		end
	end
	return nil
end

--> Checks `value` against `node`. Returns nil, or the first problem with its path under `root`.
function Schema.check(node: Node, value: any, root: string?): string?
	return problem(node, value, {}, root or "Data")
end

const function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	const result = {}
	for key, item in value do
		result[key] = copy(item)
	end
	return result
end

--> A fresh copy of the default value of `node`.
function Schema.default(node: Node): any
	return copy(node.default)
end

--> Fills what `value` lacks with defaults, in place, and returns it (or the default, when it is nil).
--> Present values are never changed, whatever they hold; `check` reports those.
function Schema.reconcile(node: Node, value: any): any
	if value == nil then
		return Schema.default(node)
	elseif type(value) ~= "table" then
		return value
	end
	const kind = node.kind
	if kind == "record" then
		for name, field in node.fields :: { [string]: Node } do
			value[name] = Schema.reconcile(field, value[name])
		end
	elseif kind == "array" or kind == "map" then
		for key, item in value do
			value[key] = Schema.reconcile(node.item :: Node, item)
		end
	elseif kind == "optional" then
		return Schema.reconcile(node.item :: Node, value)
	end
	return value
end

-- A node, with its default checked against its own rules.
const function build(node: Node): Node
	if node.kind ~= "optional" and node.kind ~= "any" then
		const found = Schema.check(node, node.default, "default")
		assert(found == nil, `KeepBlox schema: {found}`)
	end
	return table.freeze(node)
end

function Schema.number(options: Options?): Node
	const o: Options = options or {}
	return build({ kind = "number", default = o.default or 0, min = o.min, max = o.max, integer = o.integer })
end

function Schema.string(options: Options?): Node
	const o: Options = options or {}
	return build({ kind = "string", default = o.default or "", maxLength = o.maxLength })
end

function Schema.boolean(options: Options?): Node
	const o: Options = options or {}
	return build({ kind = "boolean", default = o.default == true })
end

function Schema.buffer(options: Options?): Node
	const o: Options = options or {}
	return build({ kind = "buffer", default = o.default or buffer.create(0), maxLength = o.maxLength })
end

--> One of the given strings. The default is the first value unless given.
function Schema.enum(values: { string }, options: Options?): Node
	assert(#values > 0, "KeepBlox schema: an enum needs at least one value")
	const set = {}
	for _, value in values do
		set[value] = true
	end
	const o: Options = options or {}
	return build({ kind = "enum", default = o.default or values[1], values = set })
end

--> A table with named fields. `open = true` allows fields the schema does not name.
function Schema.record(fields: { [string]: Node }, options: Options?): Node
	const default = {}
	for name, field in fields do
		default[name] = Schema.default(field)
	end
	return build({
		kind = "record",
		default = default,
		fields = table.freeze(table.clone(fields)),
		open = options and options.open == true,
	})
end

--> A list of `item`, at most `max` long.
function Schema.array(item: Node, options: Options?): Node
	return build({ kind = "array", default = {}, item = item, maxItems = options and options.max })
end

--> A dictionary of string keys to `item`, at most `max` entries.
function Schema.map(item: Node, options: Options?): Node
	return build({ kind = "map", default = {}, item = item, maxItems = options and options.max })
end

--> `item`, or nil. Its default is nil.
function Schema.optional(item: Node): Node
	return build({ kind = "optional", default = nil, item = item })
end

--> Anything storable; not checked.
function Schema.any(options: Options?): Node
	return build({ kind = "any", default = options and options.default })
end

return Schema
