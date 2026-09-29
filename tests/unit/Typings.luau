--!strict
--- The roblox-ts declarations (types/index.d.ts) keep up with the Luau API (ProfileStore#12: its
--- TypeScript types went stale). Every field of Store, Profile and the module itself must be declared.
const Spec = require("../Spec")
const fs = require("@lune/fs")

const DECLARATIONS = fs.readFile("types/index.d.ts")

-- The field names of the Luau type `name` in `path`.
const function fields(path: string, name: string): { string }
	const source = fs.readFile(path)
	const body = assert(string.match(source, `\nexport type {name} = (%b\{\})`), `no type {name} in {path}`)
	const found = {}
	for line in string.gmatch(body, "[^\n]+") do
		const field = string.match(line, "^\tread ([%a_][%w_]*):") or string.match(line, "^\t([%a_][%w_]*):")
		if field then
			table.insert(found, field)
		end
	end
	return found
end

-- The names `KeepBlox.x = ...` in src/init.luau, and its functions.
const function exported(): { string }
	const found = {}
	for name in string.gmatch(fs.readFile("src/init.luau"), "\nKeepBlox%.([%a_]+) =") do
		table.insert(found, name)
	end
	for name in string.gmatch(fs.readFile("src/init.luau"), "\nfunction KeepBlox%.([%a_]+)%(") do
		table.insert(found, name)
	end
	return found
end

const function check(names: { string }, where: string)
	Spec.truthy(#names > 0, `found the fields of {where}`)
	for _, name in names do
		Spec.truthy(
			string.find(DECLARATIONS, `\n\t\t{name}[?(:]`) ~= nil
				or string.find(DECLARATIONS, `\n\t\treadonly {name}[?:]`) ~= nil
				or string.find(DECLARATIONS, `\n\t{name}[<(:]`) ~= nil
				or string.find(DECLARATIONS, `\n\treadonly {name}:`) ~= nil,
			`{where}.{name} is declared in types/index.d.ts`
		)
	end
end

Spec.test("Typings: every Store and Profile field, and every export, is declared for roblox-ts", function()
	check(fields("src/Store.luau", "Store"), "Store")
	check(fields("src/Profile.luau", "Profile"), "Profile")
	check(exported(), "KeepBlox")
end)

return nil
