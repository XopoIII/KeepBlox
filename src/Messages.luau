--!strict
--- Offline messages, as stored: ProfileStore's `GlobalUpdates = {lastIndex, {{index, message}, ...}}`.
--- ProfileService's older entries, `{index, version, locked, message}`, are read too: the message is
--- always an entry's last element.
---
--- A message leaves the queue only in the same write that stores its effect on the data. So it is
--- consumed exactly once: until that write lands it stays queued, and it comes back after a crash
--- (guarantee 8). A full queue refuses the new message; nothing is dropped to make room, unlike
--- ProfileStore.
const Record = require("./Record")

export type Entry = { index: number, message: any }

export type Sent =
	{ kind: "sent", index: number, owner: Record.Session?, loadCount: number }
	| { kind: "full" }
	| { kind: "foreign" }

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
--> the queue, as ProfileStore does; a foreign value is left alone.
function Messages.append(value: any, message: any, limit: number): (any?, Sent)
	const kind = Record.classify(value)
	if kind == "foreign" then
		return nil, { kind = "foreign" }
	end
	const record = if kind == "missing" then { GlobalUpdates = { 0, {} } } else value
	const queue = record.GlobalUpdates
	if #queue[2] >= limit then
		return nil, { kind = "full" }
	end
	queue[1] += 1
	table.insert(queue[2], { queue[1], message })
	const meta = record.MetaData
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
