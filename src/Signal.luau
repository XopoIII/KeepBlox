--!strict
--- A small typed signal. Each listener runs in its own thread (through `spawn`), as engine signals do,
--- so a listener that yields or errors never stalls the library.

export type Connection = {
	connected: boolean,
	disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	connect: (self: Signal<T...>, listener: (T...) -> ()) -> Connection,
	fire: (self: Signal<T...>, T...) -> (),
	--> Removes every listener.
	destroy: (self: Signal<T...>) -> (),
}

const Signal = {}

--> A signal whose listeners run through `spawn` (the seam's `clock.spawn`).
function Signal.new<T...>(spawn: (fn: (...any) -> (), ...any) -> ()): Signal<T...>
	local listeners: { { fn: (T...) -> (), connection: Connection } } = {}

	return {
		connect = function(_: Signal<T...>, listener: (T...) -> ()): Connection
			-- Forward-declared: the connection's disconnect removes its own entry.
			local entry: { fn: (T...) -> (), connection: Connection }
			const connection: Connection = {
				connected = true,
				disconnect = function(self: Connection)
					if not self.connected then
						return
					end
					self.connected = false
					-- Drop the entry, or a long-lived signal (a store's onError) would grow by every
					-- connection ever made, and every fire would clone the whole of it.
					const index = table.find(listeners, entry)
					if index then
						table.remove(listeners, index)
					end
				end,
			}
			entry = { fn = listener, connection = connection }
			table.insert(listeners, entry)
			return connection
		end,
		fire = function(_: Signal<T...>, ...: T...)
			for _, entry in table.clone(listeners) do
				if entry.connection.connected then
					spawn(entry.fn :: any, ...)
				end
			end
		end,
		destroy = function(_: Signal<T...>)
			for _, entry in listeners do
				entry.connection.connected = false
			end
			listeners = {}
		end,
	}
end

return Signal
