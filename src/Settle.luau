--!strict
--- Before a key is loaded: waiting for what this server is still doing with it.
---
--- A player who leaves and joins the same server again (a quick rejoin, or a teleport that failed) must
--- not get "open", whatever their earlier load or session was doing. A session being released is waited
--- for, and then the key is claimed afresh. A load still in flight whose caller is gone (the player left,
--- or the game cancelled its thread) is waited for as its heir: it hands over the session it opens (see
--- Opening), or, when it opens none, the key is claimed afresh once it is over.
const Claim = require("./Claim")
const Opening = require("./Opening")
const Profile = require("./Profile")
const Services = require("./Services")
const Session = require("./Session")

--> What the wait reads of its store.
export type State = {
	sessions: { [string]: Session.Session },
	--> The keys being loaded.
	opening: { [string]: Opening.Opening },
	closing: () -> boolean,
}

-- How often the wait looks again.
const POLL = 0.1

const Settle = {}

--> Waits while this server is still releasing `key`, or still loading it for a caller who is gone, with
--> `heir` as this load, which takes the session over when no earlier heir wants it. Returns a failure when the wait must stop, or the profile the earlier
--> load handed over; neither when the key is this load's to claim (or "open").
function Settle.wait(
	state: State,
	clock: Services.Clock,
	key: string,
	heir: Opening.Heir,
	deadline: number
): (Claim.Failure?, Profile.Profile<any>?)
	while true do
		const handed = heir.profile
		if handed then
			return nil, handed
		end
		const existing = state.sessions[key]
		const opening = state.opening[key]
		-- A load in flight for a caller who is gone is waited for by every later load; the first of them
		-- that still wants the session is its heir.
		const inherited = opening ~= nil and Opening.gone(opening)
		if inherited and not Opening.wants((opening :: Opening.Opening).heir) then
			(opening :: Opening.Opening).heir = heir
		end
		const releasing = existing ~= nil and existing.releasing
		if not releasing and not inherited then
			return nil, nil
		elseif state.closing() then
			return "closing", nil
		elseif heir.cancel and heir.cancel() then
			return "cancelled", nil
		elseif clock.now() >= deadline then
			return "timeout", nil
		end
		clock.wait(math.min(POLL, deadline - clock.now()))
	end
end

return Settle
