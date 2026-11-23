--!strict
--- The identity a session writes its heartbeat and its lock under.
---
--- A live server has `game.JobId`, and that is its identity. A Studio session has an empty one, and
--- a heartbeat written under no key at all is worse than no heartbeat: the MemoryStore call is
--- refused, every newcomer is left unable to tell a dead session from a live one, and the profile it
--- should have taken is refused instead. So a session without a JobId is given one, once, prefixed
--- so a MemoryStore key or a log line says where it came from.
const Identity = {}

--> `real` when the server has one, else a minted `studio-...` id. An empty mint is an error: the
--> identity is a key, and a key that is empty is the defect this module exists to prevent.
function Identity.job(real: string, mint: () -> string): string
	if real ~= "" then
		return real
	end
	const made = mint()
	if made == "" then
		error("a session identity cannot be empty", 2)
	end
	return "studio-" .. made
end

return table.freeze(Identity)
