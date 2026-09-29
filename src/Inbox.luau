--!strict
--- One session's incoming messages: who handles each one, and which are done.
---
--- Each message goes to the handlers one at a time, in the order they were added, until one of them
--- calls `processed()`. The handlers run in the inbox's own thread, one message after another. So a
--- handler that yields holds up the queue; it cannot let a second handler take the same message,
--- which ProfileStore allows. A processed message is removed from the stored queue by the same write
--- that stores what the handler did (see Messages).
const Messages = require("./Messages")
const Record = require("./Record")
const Services = require("./Services")

export type Handler = (message: any, processed: () -> ()) -> ()

export type Inbox = {
	--> Adds a handler. Messages waiting unprocessed are offered to it at once.
	handle: (self: Inbox, handler: Handler) -> (),
	--> Takes the messages a write found stored; new ones are delivered.
	receive: (self: Inbox, entries: { Messages.Entry }) -> (),
	--> The messages processed and not yet removed from the store; a write takes this snapshot.
	processed: (self: Inbox) -> { [number]: boolean },
	--> Forgets messages a write removed from the store.
	removed: (self: Inbox, indices: { [number]: boolean }) -> (),
	--> Stops delivering (the session ended).
	close: (self: Inbox) -> (),
}

const Inbox = {}

--> An inbox that calls `changed()` whenever a message is processed, so the session saves soon, and
--> `report` when a handler throws.
function Inbox.new(clock: Services.Clock, changed: () -> (), report: (message: string) -> ()): Inbox
	const handlers: { Handler } = {}
	const pending: { Messages.Entry } = {} -- delivered or waiting, not yet processed
	const known: { [number]: boolean } = {}
	const done: { [number]: boolean } = {}
	const queue: { { entry: Messages.Entry, handlers: { Handler } } } = {}
	local running = false
	local closed = false

	const function drain()
		if running then
			return
		end
		running = true
		clock.spawn(function()
			while not closed and #queue > 0 do
				const job = table.remove(queue, 1) :: { entry: Messages.Entry, handlers: { Handler } }
				const entry = job.entry
				for _, handler in job.handlers do
					if done[entry.index] or closed then
						break
					end
					local claimed = false
					const ok, problem = pcall(handler, Record.copy(entry.message), function()
						if not claimed and not closed then
							claimed = true
							done[entry.index] = true
							changed()
						end
					end)
					if not ok then
						report(`a message handler failed: {problem}`)
					end
				end
			end
			running = false
		end)
	end

	return {
		handle = function(_: Inbox, handler: Handler)
			table.insert(handlers, handler)
			for _, entry in pending do
				if not done[entry.index] then
					table.insert(queue, { entry = entry, handlers = { handler } })
				end
			end
			drain()
		end,
		receive = function(_: Inbox, entries: { Messages.Entry })
			for _, entry in entries do
				if not known[entry.index] then
					known[entry.index] = true
					table.insert(pending, entry)
					if #handlers > 0 then
						table.insert(queue, { entry = entry, handlers = table.clone(handlers) })
					end
				end
			end
			drain()
		end,
		processed = function(_: Inbox): { [number]: boolean }
			return table.clone(done)
		end,
		removed = function(_: Inbox, indices: { [number]: boolean })
			local index = 1
			while index <= #pending do
				if indices[pending[index].index] then
					table.remove(pending, index)
				else
					index += 1
				end
			end
			for removed in indices do
				done[removed] = nil
			end
		end,
		close = function(_: Inbox)
			closed = true
		end,
	}
end

return Inbox
