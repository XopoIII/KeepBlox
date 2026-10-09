--!strict
--- The signal behind `onSaving`, `onSaved`, `onEnded` and a store's `onError` (src/Signal.luau).
const Signal = require("@keepblox/Signal")
const Spec = require("../Spec")

-- Runs a listener at once, as `task.spawn` does for one that does not yield.
const function now(fn: (...any) -> (), ...: any)
	fn(...)
end

Spec.test("Signal: listeners run in the order they connected, with the fired values", function()
	const signal: Signal.Signal<string, number> = Signal.new(now)
	const heard: { string } = {}
	signal:connect(function(word: string, count: number)
		table.insert(heard, `a:{word}:{count}`)
	end)
	signal:connect(function(word: string, count: number)
		table.insert(heard, `b:{word}:{count}`)
	end)
	signal:fire("x", 1)
	signal:fire("y", 2)
	Spec.equal(heard, { "a:x:1", "b:x:1", "a:y:2", "b:y:2" })
end)

Spec.test("Signal: a disconnected listener is not run, and the others keep their order", function()
	const signal: Signal.Signal<> = Signal.new(now)
	const heard: { string } = {}
	const connections: { Signal.Connection } = {}
	for _, name in { "a", "b", "c" } do
		table.insert(
			connections,
			signal:connect(function()
				table.insert(heard, name)
			end)
		)
	end
	Spec.equal(connections[2].connected, true)
	connections[2]:disconnect()
	Spec.equal(connections[2].connected, false)
	signal:fire()
	Spec.equal(heard, { "a", "c" })
	-- A second disconnect is a no-op: it must not take another listener's place in the list with it.
	connections[2]:disconnect()
	signal:fire()
	Spec.equal(heard, { "a", "c", "a", "c" })
	Spec.equal(connections[1].connected, true)
	Spec.equal(connections[3].connected, true)
end)

Spec.test("Signal: a listener disconnected during a fire is not run by that fire", function()
	const signal: Signal.Signal<> = Signal.new(now)
	const heard: { string } = {}
	local first: Signal.Connection
	local second: Signal.Connection
	first = signal:connect(function()
		table.insert(heard, "first")
		-- It drops itself and the listener after it, in the middle of the fire.
		first:disconnect()
		second:disconnect()
	end)
	second = signal:connect(function()
		table.insert(heard, "second")
	end)
	signal:connect(function()
		table.insert(heard, "third")
	end)
	signal:fire()
	Spec.equal(heard, { "first", "third" })
	signal:fire()
	Spec.equal(heard, { "first", "third", "third" })
end)

Spec.test("Signal: destroy silences every listener, and a later disconnect is harmless", function()
	const signal: Signal.Signal<> = Signal.new(now)
	local runs = 0
	const connection = signal:connect(function()
		runs += 1
	end)
	signal:fire()
	Spec.equal(runs, 1)
	signal:destroy()
	Spec.equal(connection.connected, false)
	signal:fire()
	Spec.equal(runs, 1)
	connection:disconnect()
	-- The signal still works for a listener connected after it was destroyed.
	signal:connect(function()
		runs += 10
	end)
	signal:fire()
	Spec.equal(runs, 11)
end)

-- Connects one listener, and remembers it only weakly: whether it is still there says who holds it.
const function connectWeakly(signal: Signal.Signal<>, weak: { [string]: any }, name: string, drop: boolean)
	-- It closes over a value of its own: a function with nothing to close over is shared by every call
	-- of this one and never collected, which would say nothing about the signal.
	const own = { runs = 0 }
	const listener = function()
		own.runs += 1
	end
	weak[name] = listener
	const connection = signal:connect(listener)
	if drop then
		connection:disconnect()
	end
end

Spec.test("Signal: disconnect lets the listener go, and a connected one is kept", function()
	-- A long-lived signal (a store's onError) must not grow by every connection ever made. The signal
	-- shows no count, so the collector is the witness: once disconnected, nothing holds the listener.
	const signal: Signal.Signal<> = Signal.new(now)
	const weak: { [string]: any } = setmetatable({}, { __mode = "v" }) :: any
	connectWeakly(signal, weak, "dropped", true)
	connectWeakly(signal, weak, "kept", false)
	Spec.equal(type(weak.dropped), "function")
	-- Garbage until the collector has been round; far more than one full cycle needs.
	local rounds = 0
	while weak.dropped ~= nil and rounds < 20_000 do
		const garbage = table.create(1024, rounds)
		rounds += #garbage / 1024
	end
	Spec.equal(weak.dropped, nil, `the disconnected listener after {rounds} rounds of garbage`)
	-- The control: the same pressure did not take the listener the signal still holds.
	Spec.equal(type(weak.kept), "function")
	local fired = false
	signal:connect(function()
		fired = true
	end)
	signal:fire()
	Spec.equal(fired, true)
end)

return nil
