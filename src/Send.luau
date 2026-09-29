--!strict
--- Sending an offline message to a key: `store:message(key, message)`.
---
--- The message is queued in the key's record, whether or not anyone holds it, and survives until a
--- session processes it. After queueing, the owner is told to save soon: directly when it is this
--- server, or with ProfileStore's `{LoadCount}` message on "PS_"..GUID when it is another. A full
--- queue refuses the message and says so; nothing already queued is dropped.
const Call = require("./Call")
const Messages = require("./Messages")
const Session = require("./Session")
const Validate = require("./Validate")

export type Result = { ok: true } | { ok: false, reason: "full" | "foreign" | "failed" }

--> What `Send` needs from a store.
export type Internals = {
	context: () -> Session.Context,
	sessions: { [string]: Session.Session },
}

const ATTEMPTS = 5

const Send = {}

function Send.message(internals: Internals, key: string, message: any): Result
	assert(type(key) == "string" and #key > 0 and #key <= 50, "KeepBlox: a key is 1-50 characters")
	assert(type(message) == "table", "KeepBlox: a message is a table")
	const encoded, problem = Validate.check(message, "message")
	assert(encoded, `KeepBlox: the message cannot be stored: {problem}`)
	const context = internals.context()
	const clock = context.services.clock
	local delay = context.config.backoffMin
	for _ = 1, ATTEMPTS do
		local sent: Messages.Sent? = nil
		const ok = Call.run(
			clock,
			context.config.callTimeout,
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any): any
				const record, outcome = Messages.append(value, message, Messages.LIMIT)
				sent = outcome
				return record
			end
		)
		if ok and sent then
			const outcome = sent :: Messages.Sent
			if outcome.kind == "full" or outcome.kind == "foreign" then
				context.report(key, `message refused: the queue is {outcome.kind}`)
				return { ok = false, reason = outcome.kind }
			end
			const here = internals.sessions[key]
			if here then
				here.saveSoon = true
			elseif outcome.kind == "sent" and outcome.owner and type(outcome.owner[3]) == "string" then
				const topic = `PS_{outcome.owner[3]}`
				clock.spawn(function()
					pcall(function()
						context.services.messaging:PublishAsync(topic, { LoadCount = outcome.loadCount })
					end)
				end)
			end
			return { ok = true }
		end
		clock.wait(delay)
		delay = math.min(delay * 2, context.config.backoffMax)
	end
	context.report(key, "message not sent: the data store kept failing")
	return { ok = false, reason = "failed" }
end

return Send
