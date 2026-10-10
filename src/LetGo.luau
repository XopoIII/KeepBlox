--!strict
--- Letting go of a key a load took, or may have taken, but will not keep (see Claim).
---
--- What the load took is given back whole. A key taken from a server that died may have that server's
--- last beat behind it, play newer than the record (see Recover): the beat is stored before the key is
--- freed, since the next load finds a free key with no previous owner to recover from (issue 33). A
--- beat this server could not store is noted in the record as it is freed, for the next load to store
--- (see Owed, issue 36).
---
--- A key this server still holds with no session for it, whatever left it so, is freed when another
--- server asks for it (`LetGo.stray`, issue 37).
const Call = require("./Call")
const Lock = require("./Lock")
const Record = require("./Record")
const Recover = require("./Recover")
const Session = require("./Session")
const Spare = require("./Spare")

const LetGo = {}

--> Frees a key this server has just taken but no longer wants (the player left, a shutdown, a load
--> that failed past its claim). The write frees the key only while this very session holds it, so it
--> is tried again, with the load's backoff and until its deadline, when the data store does not answer:
--> a key left held by a live server that has no session for it is handed to nobody. `owed` is the
--> owner the key was taken from, when its last beat is still to be stored.
function LetGo.giveBack(context: Session.Context, key: string, loadCount: number, owed: Lock.Previous?)
	const clock = context.services.clock
	const config = context.config
	const deadline = context.deadline or clock.now() + config.loadTimeout
	local delay = config.backoffMin
	while true do
		const ok, err = Call.run(
			clock,
			config.callTimeout,
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any): any
				const payload: Lock.Payload = { data = nil, release = true, owed = owed }
				return (Lock.save(value, context.identity, loadCount, payload, clock.time()))
			end
		)
		if ok then
			return
		end
		context.report(key, `a key its load gave up was not given back: {err}`)
		if clock.now() + delay >= deadline then
			return
		end
		clock.wait(delay)
		delay = math.min(delay * 2, config.backoffMax)
	end
end

--> Gives back all of what a claim took, for a load that will not keep it: the previous owner's last
--> beat is stored first, unless the load already saw to it (`taken.previous` is nil then, see Enter),
--> and then the key is freed. A beat that could not be stored is left to the next load. A key with an
--> unfinished trade keeps its journal for the next load to settle, as a load that goes on would settle
--> it before anything else.
function LetGo.undo(context: Session.Context, key: string, taken: Lock.Taken)
	const previous = taken.previous
	local owed: Lock.Previous? = nil
	if previous ~= nil and Record.ours(taken.record.MetaData).trade == nil then
		const ok, problem, unstored = pcall(Recover.run, context, key, taken.loadCount, taken.record, previous)
		if not ok then
			context.report(key, `the previous owner's last beat could not be stored: {problem}`)
		end
		owed = if not ok or unstored then previous else nil
	end
	LetGo.giveBack(context, key, taken.loadCount, owed)
end

--> Lets go of `key` in the background if a claim of this load may have landed unanswered: a load that
--> gives up must not leave its live server holding a key it never learnt it had. The write is tried
--> again with the load's backoff while the budget leaves saves their reserve, for `loadTimeout` of its
--> own (a load that ran out its deadline has none left), and one that never lands is reported.
function LetGo.disown(context: Session.Context, key: string)
	const clock = context.services.clock
	const config = context.config
	clock.spawn(function()
		const deadline = clock.now() + config.loadTimeout
		local delay = config.backoffMin
		while true do
			const ok, err = Call.run(
				clock,
				config.callTimeout,
				context.dataStore.UpdateAsync,
				context.dataStore,
				key,
				function(value: any): any
					return Lock.disown(value, context.identity, clock.time())
				end
			)
			if ok then
				return
			elseif clock.now() + delay >= deadline then
				context.report(key, `a key its load may have taken could not be let go: {err}`)
				return
			end
			clock.wait(delay)
			delay = math.min(delay * 2, config.backoffMax)
			-- Saves go first (see Spare): a try fired at a spent budget only fails, and starves them.
			Spare.wait(context, Spare.RESERVE, deadline, context.closing)
		end
	end)
end

--> Frees `key` for a server that asked this one to hand it over, when the record names this server
--> at the load count `loadCount` though the store has neither a session for the key nor a load of it
--> (the caller's to know, see Upkeep.beat). Such a key is renewed and released by nobody, and a
--> server that beats is never judged dead, so without this it would be handed to nobody for as long
--> as the server lives. A load of the key that starts meanwhile moves the count, and the write then
--> frees nothing. One write, and only on this path; the server asking tries the key again within a
--> second.
function LetGo.stray(context: Session.Context, key: string, loadCount: number)
	const clock = context.services.clock
	local freed = false
	const ok, err = Call.run(
		clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		key,
		function(value: any): any
			const written = Lock.disown(value, context.identity, clock.time(), loadCount)
			freed = written ~= nil
			return written
		end
	)
	if not ok then
		context.report(key, `a key held with no session was not freed for the server asking for it: {err}`)
	elseif freed then
		context.report(key, "a key held with no session was freed for the server asking for it")
	end
end

return LetGo
