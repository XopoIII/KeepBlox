--!strict
--- Misuse of KeepBlox's public API that must NOT type-check, under either solver: proof that the checks
--- of `Game.luau` read the real types rather than passing on `any`. `scripts/type-check.sh` expects
--- exactly one error on each line marked `-- error`, and no other. A line marked
--- `-- error (new solver)` is one only the new solver refuses.
const KeepBlox = require("@keepblox")

const store: KeepBlox.Store = KeepBlox.store("Profiles", { template = { coins = 0 } })
const result = store:load("u_1")
if result.ok then
	const profile: KeepBlox.Profile = result.profile
	const count: string = profile.loadCount -- error
	const listener = function(final: string)
		print(final)
	end
	profile.onSaving:connect(listener) -- error
	print(count)
end
const name: number = store.name -- error
print(name)

-- A misspelt setting is a type error under the new solver; the old one cannot tell a table with an
-- unknown field from one without, and leaves it to the assert when the store opens.
const options: KeepBlox.StoreOptions = {
	template = { coins = 0 },
	config = { loadTimout = 60 }, -- error (new solver)
}
print(options)

return nil
