--!strict
--- Trades: one change to two profiles that lands in both or in neither, even if the server dies midway.
---
---     const result = store:trade(`u_{a.UserId}`, `u_{b.UserId}`, function(dataA, dataB)
---         dataA.coins -= 100; dataB.coins += 100
---         table.insert(dataB.pets, table.remove(dataA.pets, index))
---     end)
---
--- Both profiles must be open on this server (players trade with players they can see). The change
--- is applied to both profiles' data at once, then committed:
---
--- 1. A trade record `<id>` is created in "<store>__trades", open.
--- 2. Each profile is saved with the change and a journal: the trade's id and its data from before.
--- 3. The trade record goes from open to done, in one UpdateAsync: the commit point.
--- 4. The journals are cleared.
---
--- Both profiles' write lanes are held throughout, so nothing else is saved meanwhile. A profile loaded
--- with a journal (its server died midway) settles the trade first: a trade still open is marked
--- aborted, in one UpdateAsync, so exactly one outcome wins; done keeps the data, aborted puts back the
--- data from before. The other profile settles the same way, to the same outcome.
---
--- A trade that fails (a profile lost, the store failing, `trade` throwing, data that cannot be stored)
--- is aborted, and both profiles' data goes back to what it was, in place. Changes the game made to
--- those two profiles during the trade's round trips are undone with it.
const Call = require("./Call")
const Lock = require("./Lock")
const Migrate = require("./Migrate")
const Record = require("./Record")
const Schema = require("./Schema")
const Services = require("./Services")
const Session = require("./Session")
const Validate = require("./Validate")

export type Failure = "notHere" | "error" | "refused" | "lost" | "failed"

export type Result = { ok: true } | { ok: false, reason: Failure, message: string? }

const Trade = {}

-- Puts `data` back to `before`, in place.
const function restore(data: { [any]: any }, before: { [any]: any })
	for key in data do
		data[key] = nil
	end
	for key, value in Record.copy(before) do
		data[key] = value
	end
end

const function tradesStore(context: Session.Context, storeName: string): Services.DataStore
	return context.services.dataStores:GetDataStore(`{storeName}__trades`)
end

-- Moves trade `id` to `want` if it is still open (or missing, when aborting). Returns the outcome
-- that stands, or nil when the store could not be reached.
function Trade.decide(context: Session.Context, storeName: string, id: string, want: "done" | "aborted"): string?
	const store = tradesStore(context, storeName)
	local outcome: string? = nil
	const ok = Call.run(
		context.services.clock,
		context.config.callTimeout,
		store.UpdateAsync,
		store,
		id,
		function(value: any): any
			if type(value) ~= "table" then
				outcome = "aborted"
				return if want == "aborted" then { state = "aborted" } else nil
			end
			if value.state == "open" then
				value.state = want
			end
			outcome = value.state
			return value
		end
	)
	return if ok then outcome else nil
end

-- One lock-guarded write of `session`'s record, inside its lane (the caller holds it).
-- Sessions a trade's write found lost: ended once the trade is over (ending freezes the data, which the
-- trade may still have to put back).
const lostHere: { [Session.Session]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- `data` and a journal's `before` are as stored (see `stored`), and go with the version they are at, so
-- no migration runs on them twice.
const function write(context: Session.Context, session: Session.Session, data: any?, journal: any): boolean
	const payload: Lock.Payload = {
		data = data,
		release = false,
		journal = journal,
		snap = session.snapSeq,
		schemaVersion = if data ~= nil then context.plan.write else nil,
	}
	local lost = false
	const ok = Call.run(
		context.services.clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		session.key,
		function(value: any): any
			const record, result =
				Lock.save(value, context.identity, session.loadCount, payload, context.services.clock.time())
			lost = result.kind == "lost"
			return record
		end
	)
	if ok and lost then
		lostHere[session] = true
	end
	if ok and not lost and data ~= nil then
		const encoded = Validate.check(data, "Data")
		if encoded then
			session.storedText = encoded.text
			session.storedSize = encoded.size
		end
	end
	return ok and not lost
end

-- `data` as the data store stores it: a copy, at the plan's `write` version (see Migrate).
const function stored(context: Session.Context, data: any): (any, string?)
	return Migrate.store(context.plan, Record.copy(data))
end

-- Retries `decide` until it answers, the server closes, or (not `patient`) the load's deadline passes.
const function settle(
	context: Session.Context,
	storeName: string,
	id: string,
	want: "done" | "aborted",
	patient: boolean
): string?
	const clock = context.services.clock
	const deadline = context.deadline or clock.now() + context.config.loadTimeout
	local delay = context.config.backoffMin
	while true do
		const outcome = Trade.decide(context, storeName, id, want)
		if outcome or context.closing() or (not patient and clock.now() >= deadline) then
			return outcome
		end
		clock.wait(delay)
		delay = math.min(delay * 2, context.config.backoffMax)
	end
end

-- The trade, with both lanes held.
const function inLanes(
	storeName: string,
	a: Session.Session,
	b: Session.Session,
	change: (dataA: any, dataB: any) -> ()
): Result
	if not (a.active and b.active and not a.releasing and not b.releasing) then
		return { ok = false, reason = "lost" }
	end
	const context = a.context
	const dataA, dataB = a.profile.Data, b.profile.Data
	const beforeA, beforeB = Record.copy(dataA), Record.copy(dataB)
	const ok, problem = pcall(change, dataA, dataB)
	const function undo()
		restore(dataA, beforeA)
		restore(dataB, beforeB)
	end
	if not ok then
		undo()
		return { ok = false, reason = "error", message = tostring(problem) }
	end
	const afterA, afterB = Record.copy(dataA), Record.copy(dataB)
	for _, pair in { { afterA, "dataA" }, { afterB, "dataB" } } do
		local _, refusal = Validate.check(pair[1], pair[2])
		if refusal == nil and context.plan.schema then
			refusal = Schema.check(context.plan.schema, pair[1])
		end
		if refusal then
			undo()
			return { ok = false, reason = "refused", message = refusal }
		end
	end
	const storedA, refusedA = stored(context, afterA)
	const storedB, refusedB = stored(context, afterB)
	const keptA, refusedKeptA = stored(context, beforeA)
	const keptB, refusedKeptB = stored(context, beforeB)
	const turned = refusedA or refusedB or refusedKeptA or refusedKeptB
	if turned then
		undo()
		return { ok = false, reason = "refused", message = turned }
	end
	const id = context.services.guid()
	const trades = tradesStore(context, storeName)
	const opened = Call.run(
		context.services.clock,
		context.config.callTimeout,
		trades.UpdateAsync,
		trades,
		id,
		function(value: any): any
			return if value == nil
				then { state = "open", a = a.key, b = b.key, at = context.services.clock.time() }
				else nil
		end
	)
	if not opened then
		undo()
		return { ok = false, reason = "failed", message = "the trade record could not be written" }
	end
	-- A write that failed may still have landed ("a failed write does not always guarantee that the
	-- backend write did not occur"), so a side counts as touched once its write was tried.
	const wroteA = write(context, a, storedA, { id = id, before = keptA })
	const triedB = wroteA
	const wroteB = triedB and write(b.context, b, storedB, { id = id, before = keptB })
	const outcome = settle(context, storeName, id, if wroteA and wroteB then "done" else "aborted", true)
	if outcome == nil then
		-- The server is closing and the outcome is still unknown (a "done" may have landed and failed to
		-- answer). Nothing is undone and the journals stay: each profile settles the trade when it next
		-- loads, both from the same trade record, so both reach the same outcome.
		return { ok = false, reason = "failed", message = "the trade settles when the profiles next load" }
	end
	if outcome == "done" then
		-- Committed: the journals go with the next writes if not now.
		if not write(context, a, nil, false) then
			a.clearJournal = true
		end
		if not write(b.context, b, nil, false) then
			b.clearJournal = true
		end
		return { ok = true }
	end
	undo()
	if outcome == "aborted" then
		-- Nothing may keep the change: put back what was written, journals cleared.
		if not write(context, a, keptA, false) then
			a.clearJournal = true
		end
		if triedB and not write(b.context, b, keptB, false) then
			b.clearJournal = true
		end
	end
	return {
		ok = false,
		reason = if wroteA and wroteB then "failed" else "lost",
		message = "the trade was not committed",
	}
end

--> Trades between two profiles open on this server (see the header).
function Trade.run(
	storeName: string,
	sessions: { [string]: Session.Session },
	keyA: string,
	keyB: string,
	change: (dataA: any, dataB: any) -> ()
): Result
	assert(type(change) == "function", "KeepBlox: trade needs a function")
	assert(keyA ~= keyB, "KeepBlox: a trade needs two different keys")
	const a, b = sessions[keyA], sessions[keyB]
	if a == nil or b == nil or not a.active or not b.active then
		return { ok = false, reason = "notHere" }
	end
	-- Lanes are always taken in key order, so two trades never wait on each other.
	const first, second = if keyA < keyB then a else b, if keyA < keyB then b else a
	a.trading, b.trading = true, true
	const ok, result = pcall(first.serial.run, first.serial, function(): Result
		return second.serial:run(inLanes, storeName, a, b, change)
	end)
	a.trading, b.trading = false, false
	if not ok then
		error(result, 0)
	end
	for _, session in { a, b } do
		if lostHere[session] then
			lostHere[session] = nil
			Session.finish(session.context, session, "lost")
		end
	end
	return result
end

--> Settles a trade left open in a record just claimed (its server died midway). Returns the data the
--> profile continues from, or nil when the outcome could not be learnt yet.
function Trade.recover(context: Session.Context, storeName: string, record: any): any?
	const journal = Record.ours(record.MetaData).trade
	if journal == nil then
		return record.Data
	end
	const outcome = settle(context, storeName, journal.id, "aborted", false)
	if outcome == nil then
		return nil
	end
	return if outcome == "done" then record.Data else journal.before
end

return Trade
