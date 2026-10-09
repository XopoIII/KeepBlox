--!strict
--- Before a key is loaded: waiting for what this server is still doing with it.
---
--- A player who leaves and joins the same server again before the release finished (a quick rejoin,
--- or a teleport that failed) must not get "open". Neither must one whose earlier load was cut short
--- by the game cancelling its thread: that load is being undone in a thread of the library's (see
--- Open). Both are waited for, and then the key is claimed afresh.
const Claim = require("./Claim")
const Services = require("./Services")
const Session = require("./Session")

--> What the wait reads of its store.
export type State = {
	sessions: { [string]: Session.Session },
	--> The keys being loaded, each with the thread that asked for it.
	opening: { [string]: thread },
	closing: () -> boolean,
}

-- How often the wait looks again.
const POLL = 0.1

const Settle = {}

--> Waits while this server is still releasing `key`, or still undoing a load of it whose caller was
--> cancelled. Returns a failure when the wait must stop.
function Settle.wait(
	state: State,
	clock: Services.Clock,
	key: string,
	cancel: (() -> boolean)?,
	deadline: number
): Claim.Failure?
	while true do
		const existing = state.sessions[key]
		const asker = state.opening[key]
		if (existing == nil or not existing.releasing) and (asker == nil or coroutine.status(asker) ~= "dead") then
			return nil
		elseif state.closing() then
			return "closing"
		elseif cancel and cancel() then
			return "cancelled"
		elseif clock.now() >= deadline then
			return "timeout"
		end
		clock.wait(math.min(POLL, deadline - clock.now()))
	end
end

return Settle
