--!strict
--- Offline messages, as stored: ProfileStore's `GlobalUpdates = {lastIndex, {{index, message}, ...}}`.
--- ProfileService's older entries, `{index, version, locked, message}`, are read too: the message is
--- always an entry's last element.
---
--- A message leaves the queue only in the same write that stores its effect on the data. So it is
--- consumed exactly once: until that write lands it stays queued, and it comes back after a crash
--- (guarantee 8). A full queue refuses the new message; nothing is dropped to make room, unlike
--- ProfileStore.
---
--- A message sent with an id (see Once) leaves the id in `GlobalUpdates[3]`, a list of `{id, at}`, by
--- the same write that queues it, so a send tried again after a try that seemed to fail queues it once.
--- A retry that finds the queue full leaves its id in `GlobalUpdates[4]`, so an earlier try that lands
--- later does not queue what the sender was told was refused.
--- The message itself is stored as given. ProfileStore and ProfileService read only the first two
--- elements of `GlobalUpdates` and write the table back as they found it, so the list stays.
const Once = require("./Once")
const Record = require("./Record")

export type Entry = { index: number, message: any }

export type Sent =
	{ kind: "sent", index: number, owner: Record.Session?, loadCount: number }
	| { kind: "full" }
	| { kind: "foreign" }
	--> The message was already queued, by an earlier try of the same send.
	| { kind: "again", owner: Record.Session?, loadCount: number }
	--> The send ran past its time and changed nothing (see Once).
	| { kind: "late" }

--> A send's id, and what the transform needs to keep it (see Once). `again` is set from the second try
--> on: a full queue such a try finds is stored with its id, since an earlier try may still land.
export type Mark = {
	id: string,
	at: number,
	now: () -> number,
	time: () -> number,
	deadline: number,
	keep: number,
	again: boolean?,
}

const Messages = {}

--> The default most messages one key can hold.
Messages.LIMIT = 1000

--> The pending messages in a record, oldest first, as copies.
function Messages.list(record: any): { Entry }
	const queue = type(record) == "table" and record.GlobalUpdates
	const entries = {}
	if type(queue) == "table" and type(queue[2]) == "table" then
		for _, entry in queue[2] do
			if type(entry) == "table" and type(entry[1]) == "number" and #entry >= 2 then
				table.insert(entries, { index = entry[1], message = Record.copy(entry[#entry]) })
			end
		end
	end
	return entries
end

--> The transform that queues `message` for a key. A key that holds nothing gets a record with only
--> the queue, as ProfileStore does; a foreign value is left alone. With `mark`, a message whose id is
--> already stored is not queued again, and none is queued past the mark's deadline.
function Messages.append(value: any, message: any, limit: number, mark: Mark?): (any?, Sent)
	const kind = Record.classify(value)
	if kind == "foreign" then
		return nil, { kind = "foreign" }
	end
	const record = if kind == "missing" then { GlobalUpdates = { 0, {} } } else value
	const queue = record.GlobalUpdates
	const meta = record.MetaData
	if mark and Once.seen(queue[3], mark.id) then
		return nil,
			{
				kind = "again",
				owner = if meta then meta.ActiveSession else nil,
				loadCount = if meta then meta.SessionLoadCount or 0 else 0,
			}
	elseif mark and Once.seen(queue[4], mark.id) then
		return nil, { kind = "full" }
	elseif mark and mark.now() > mark.deadline then
		return nil, { kind = "late" }
	end
	if #queue[2] >= limit then
		if mark and mark.again then
			queue[4] = Once.note(queue[4], mark.id, mark.at, mark.time(), mark.keep)
			return record, { kind = "full" }
		end
		return nil, { kind = "full" }
	end
	queue[1] += 1
	table.insert(queue[2], { queue[1], message })
	if mark then
		queue[3] = Once.note(queue[3], mark.id, mark.at, mark.time(), mark.keep)
	end
	return record,
		{
			kind = "sent",
			index = queue[1],
			owner = if meta then meta.ActiveSession else nil,
			loadCount = if meta then meta.SessionLoadCount or 0 else 0,
		}
end

--> Removes the messages whose indices are in `consumed` from a record's queue, in place.
function Messages.consume(record: any, consumed: { [number]: boolean })
	if next(consumed) == nil then
		return
	end
	const list = record.GlobalUpdates[2]
	local index = 1
	while index <= #list do
		if consumed[list[index][1]] then
			table.remove(list, index)
		else
			index += 1
		end
	end
end

return Messages
