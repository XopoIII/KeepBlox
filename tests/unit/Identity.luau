--!strict
--- A session's identity: a server's own JobId, or one minted for a Studio session that has none.
const Identity = require("@keepblox/Identity")
const Spec = require("../Spec")

Spec.test("Identity: a server keeps its own JobId, and nothing is minted", function()
	local minted = 0
	const id = Identity.job("9d0f-a1b2", function(): string
		minted += 1
		return "unused"
	end)
	Spec.equal(id, "9d0f-a1b2", "the server's own id")
	Spec.equal(minted, 0, "a server needs no mint")
end)

Spec.test("Identity: a Studio session mints one, prefixed, and never an empty key", function()
	local minted = 0
	const id = Identity.job("", function(): string
		minted += 1
		return "guid-1"
	end)
	Spec.equal(id, "studio-guid-1", "the minted id names where it came from")
	Spec.equal(minted, 1, "one mint per identity")
	const other = Identity.job("", function(): string
		return "guid-2"
	end)
	Spec.equal(other, "studio-guid-2", "another session is another identity")
end)

Spec.test("Identity: an empty mint is refused rather than becoming an empty key", function()
	const ok, problem = pcall(function(): string
		return Identity.job("", function(): string
			return ""
		end)
	end)
	Spec.equal(ok, false, "an empty identity is an error")
	Spec.equal(string.find(tostring(problem), "cannot be empty") ~= nil, true, "and says why")
end)

return nil
