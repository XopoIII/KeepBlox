--!strict
--- Letting go of a key a load took, or may have taken, but will not keep (see Claim).
---
--- What the load took is given back whole. A key taken from a server that died may have that server's
--- last beat behind it, play newer than the record (see Recover): the beat is stored before the key is
--- freed, since the next load finds a free key with no previous owner to recover from (issue 33).
const Call = require("./Call")
const Lock = require("./Lock")
const Record = require("./Record")
const Recover = require("./Recover")
const Session = require("./Session")

const LetGo = {}

--> Frees a key this server has just taken but no longer wants (the player left, a shutdown, a load
--> that failed past its claim). The write frees the key only while this very session holds it, so it
--> is tried again, with the load's backoff and until its deadline, when the data store does not answer:
--> a key left held by a live server that has no session for it is handed to nobody.
function LetGo.giveBack(context: Session.Context, key: string, loadCount: number)
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
				return (Lock.save(value, context.identity, loadCount, { data = nil, release = true }, clock.time()))
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
--> and then the key is freed. A key with an unfinished trade keeps its journal for the next load to
--> settle, as a load that goes on would settle it before anything else.
function LetGo.undo(context: Session.Context, key: string, taken: Lock.Taken)
	if taken.previous ~= nil and Record.ours(taken.record.MetaData).trade == nil then
		const ok, problem = pcall(Recover.run, context, key, taken.loadCount, taken.record, taken.previous)
		if not ok then
			context.report(key, `the previous owner's last beat could not be stored: {problem}`)
		end
	end
	LetGo.giveBack(context, key, taken.loadCount)
end

--> Lets go of `key` in the background if a claim of this load may have landed unanswered: a load that
--> gives up must not leave its live server holding a key it never learnt it had.
function LetGo.disown(context: Session.Context, key: string)
	const clock = context.services.clock
	clock.spawn(function()
		pcall(
			Call.run,
			clock,
			context.config.callTimeout,
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any): any
				return Lock.disown(value, context.identity, clock.time())
			end
		)
	end)
end

return LetGo
