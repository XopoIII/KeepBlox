--!strict
--- The previous owner of a key a claim takes: the session whose last beat may hold play newer than the
--- record (see Recover).
---
--- It is the session the claim takes the key from. For a free key it is the one a load that gave the key
--- back could not store the last beat of (issue 36): that load leaves a note in the record, `owed`, and
--- the next load recovers from the dead owner as if it had taken the key from it itself.
---
--- The note counts only while the key's load count is the one it was left at. Any session since has
--- played on from the stored data, so the beat is older than its play. ProfileStore and a KeepBlox
--- before 0.6.10 neither read the note nor clear it, and both count their loads, so a note they leave
--- behind is never used.
const Record = require("./Record")

--> The session whose snapshots a claim recovers from (a server that died or was cut off).
export type Previous = { jobId: string, loadCount: number, snap: number }

const Owed = {}

--> The previous owner of the key `meta` describes, as a claim by `identity` finds it, read before the
--> claim writes itself in. The note is used up by any claim.
function Owed.previous(meta: any, identity: Record.Identity): Previous?
	const ours = Record.ours(meta)
	const note = ours.owed
	ours.owed = nil
	const before = meta.ActiveSession
	if type(before) == "table" then
		if Record.isHere(before, identity) then
			return nil
		end
		return { jobId = tostring(before[2]), loadCount = meta.SessionLoadCount or 0, snap = tonumber(ours.snap) or 0 }
	end
	if
		type(note) ~= "table"
		or note.at ~= meta.SessionLoadCount
		or type(note.j) ~= "string"
		or type(note.c) ~= "number"
	then
		return nil
	end
	return { jobId = note.j, loadCount = note.c, snap = tonumber(note.q) or 0 }
end

--> Leaves the note: the session of `meta`, which gives the key back with this write, could not store
--> the last beat of `previous`.
function Owed.leave(meta: any, previous: Previous)
	Record.ours(meta).owed =
		{ j = previous.jobId, c = previous.loadCount, q = previous.snap, at = meta.SessionLoadCount }
end

return Owed
