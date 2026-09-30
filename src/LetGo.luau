--!strict
--- Letting go of a key a load took, or may have taken, but will not keep (see Claim).
const Call = require("./Call")
const Lock = require("./Lock")
const Session = require("./Session")

const LetGo = {}

--> Lets go of a key this server has just taken but no longer wants (the player left, or shutdown).
function LetGo.giveBack(context: Session.Context, key: string, loadCount: number)
	pcall(
		Call.run,
		context.services.clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		key,
		function(value: any): any
			return (
				Lock.save(
					value,
					context.identity,
					loadCount,
					{ data = nil, release = true },
					context.services.clock.time()
				)
			)
		end
	)
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
