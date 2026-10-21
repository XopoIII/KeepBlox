--!strict
--- A load in flight on this server, as its store lists it by key (see Open, Settle).
---
--- Its player may leave, or the game cancel its thread, while it stands inside a data store call it
--- cannot take back. When the same player joins this server again meanwhile (a quick rejoin, or a
--- teleport that failed), the new load is not told "open", and it does not wait for the first load to
--- be undone and then claim the key again: it waits as the first load's heir, and the first load goes
--- on and hands it the session it opens. One claim in all, and the second load answers as soon as the
--- first would have.
const Profile = require("./Profile")

--> A later load of the key, waiting to take over a load whose caller is gone.
export type Heir = {
	--> The thread of the waiting load's caller.
	thread: thread,
	--> That caller's `cancel`, made safe to ask (see Open).
	cancel: (() -> boolean)?,
	--> The profile, once it was handed over.
	profile: Profile.Profile<any>?,
}

export type Opening = {
	--> The thread that asked for the load.
	asker: thread,
	--> Its caller's `cancel`, made safe to ask (see Open).
	cancel: (() -> boolean)?,
	--> The load that would take its session over, once its caller is gone.
	heir: Heir?,
}

const Opening = {}

function Opening.new(asker: thread, cancel: (() -> boolean)?): Opening
	return { asker = asker, cancel = cancel, heir = nil }
end

--> Whether nobody is left to take the load's session: its caller's thread was cancelled, or its
--> `cancel` answers true.
function Opening.gone(opening: Opening): boolean
	return coroutine.status(opening.asker) == "dead" or (opening.cancel ~= nil and opening.cancel())
end

--> Whether `heir` still waits for the session: nothing was handed to it yet, its caller's thread is
--> alive, and its own `cancel` answers false.
function Opening.wants(heir: Heir?): boolean
	return heir ~= nil
		and heir.profile == nil
		and coroutine.status(heir.thread) ~= "dead"
		and not (heir.cancel ~= nil and heir.cancel())
end

--> The `cancel` the load itself looks at, nil when its caller gave none: its caller's, but false while
--> an heir waits for the session, so that the load goes on to open it for the heir.
function Opening.polled(opening: Opening): (() -> boolean)?
	const own = opening.cancel
	if own == nil then
		return nil
	end
	return function(): boolean
		return own() and not Opening.wants(opening.heir)
	end
end

return Opening
