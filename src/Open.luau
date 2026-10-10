--!strict
--- Loading a key: from the claim to the live session the game holds.
---
--- A player who leaves and joins the same server again before the release finished (a quick rejoin,
--- or a teleport that failed) does not get "open": the load waits for that release (see Settle), then
--- claims the key afresh. A session that is still live is a second load of the same key, and gets "open".
---
--- A template store fills keys the stored data lacks with copies from the template, deeply, on every
--- load (a schema store does the same through its defaults). Existing values are never replaced.
---
--- The load runs in a thread the library owns (see Apart), so a caller the game cancels in the middle
--- leaves nothing half done: the load runs to its end, and a session it opens, which nobody is left
--- to hold, is released at once with all it read. A later load of the key waits for that, then claims
--- the key afresh.
---
--- `cancel` is the game's code. One that throws ends the load as one that answers true does, wherever
--- the load stood, so nothing is left held or subscribed; then its error goes on to the caller.
const Apart = require("./Apart")
const Claim = require("./Claim")
const Enter = require("./Enter")
const Import = require("./Import")
const LetGo = require("./LetGo")
const Lock = require("./Lock")
const Profile = require("./Profile")
const Session = require("./Session")
const Settle = require("./Settle")
const Upkeep = require("./Upkeep")

export type LoadOptions = {
	--> Polled while the load waits; true gives up (the player left).
	cancel: (() -> boolean)?,
	--> Take the key at once from whoever holds it, as ProfileStore's `Steal = true`. For recovering a
	--> key stuck on a dead server by hand; a normal load never needs it.
	steal: boolean?,
	--> Never ask a live owner to hand the key over (no player is kicked): fail with "inUse" instead.
	--> A dead owner is still taken over, once its lease has not moved for `death` seconds. For
	--> support tools and offline edits (`store:edit`).
	quiet: boolean?,
}

export type Failure = Claim.Failure | "open" | "newerSchema" | "migration" | "schema"

export type LoadResult<T = any> = { ok: true, profile: Profile.Profile<T> } | { ok: false, reason: Failure }

--> What a load needs from its store.
export type State = Enter.State

const Open = {}

--> The game's `cancel` of `options`, made safe to ask anywhere: a throw is kept in `thrown` and
--> answers true, then and from then on.
const function guarded(options: LoadOptions?, thrown: { problem: any? }): LoadOptions?
	const cancel = options and options.cancel
	if options == nil or cancel == nil then
		return options
	end
	const safe = table.clone(options)
	safe.cancel = function(): boolean
		if thrown.problem == nil then
			const ok, answer = pcall(cancel)
			if ok then
				return answer
			end
			thrown.problem = if answer == nil then "KeepBlox: `cancel` threw nil" else answer
		end
		return true
	end
	return safe
end

const function stopListening(listener: Upkeep.Listener)
	listener.done = true
	if listener.connection then
		listener.connection:Disconnect()
	end
end

-- The load of a key marked as opening, in a thread of its own. `asker` is the thread that waits for
-- it: once the game has cancelled that thread, nobody is left to hold the profile.
const function open(state: State, key: string, options: LoadOptions?, deadline: number, asker: thread): LoadResult
	const cancel = options and options.cancel
	state.prepare()
	const services = state.base.services
	const plan = state.plan
	const context = table.clone(state.base)
	context.identity = { placeId = services.placeId, jobId = services.jobId, guid = services.guid() }
	context.deadline = deadline
	const mode: Lock.Mode = {
		force = options ~= nil and options.steal == true,
		quiet = options ~= nil and options.quiet == true,
		version = plan.write,
	}
	local template = state.storedTemplate
	const importer = state.importer
	if importer then
		const prepared = Import.prepare(context, key, importer, cancel)
		if not prepared.ok then
			state.opening[key] = nil
			return { ok = false, reason = prepared.reason }
		end
		mode.imported = importer.name
		-- An old value at this very key is converted inside the claim; one from elsewhere was read here.
		mode.adopt = if importer.fetch == nil then importer.read else nil
		if prepared.data ~= nil then
			template = prepared.data
			mode.fromImport = true
			mode.userIds = prepared.userIds
		end
	end
	const listener: Upkeep.Listener = { session = nil, connection = nil, done = false }
	Upkeep.listen(services, context.identity.guid, listener)
	mode.memory = state.beating()
	const claim = Claim.open(context, state.name, key, template, cancel, mode)
	-- The key stays `opening` until its session is listed: recovering a dead owner's play, settling a
	-- trade and checking the data all yield, and a second load of the key meanwhile would claim it again.
	if not claim.ok then
		state.opening[key] = nil
		stopListening(listener)
		return { ok = false, reason = claim.reason }
	end
	const taken = claim.taken
	-- A load that fails or throws past its claim keeps nothing: the key is given back first, with all
	-- the claim took, or it would stay held by a live server with no session to renew or to release it
	-- (issue 34).
	const function drop()
		LetGo.undo(context, key, taken)
		stopListening(listener)
	end
	const made, answer = pcall(Enter.session, state, context, key, taken, listener)
	if not made then
		drop()
		error(answer, 0) -- `Open.load` unmarks the key
	end
	const entered: Enter.Result = answer
	if not entered.ok then
		drop()
		state.opening[key] = nil
		if entered.message then
			state.onError:fire(key, entered.message)
		end
		return { ok = false, reason = entered.reason }
	end
	const session = entered.session
	const orphaned = coroutine.status(asker) == "dead"
	if orphaned or state.closing() then
		-- Nobody is left to play on this profile or to release it: its caller was cancelled, or the
		-- shutdown began after the claim landed, and listed the sessions it releases before this one
		-- was there (issue 34). It is released here with all the load read; no game ever saw the
		-- profile, so the ending's reason is heard by nobody. The key stays `opening` meanwhile, so a
		-- later load of it and the shutdown both wait for the release.
		-- A dead owner's last beat this load could not store is left to the next load (see Owed).
		session.owed = taken.previous
		-- A release that throws is tried again: this thread is all that holds the session.
		local delay = state.config.backoffMin
		while true do
			const released, problem = pcall(Session.release, context, session, "released")
			if released then
				break
			end
			state.onError:fire(key, `the release of a load nobody holds failed, and is tried again: {problem}`)
			services.clock.wait(delay)
			delay = math.min(delay * 2, state.config.backoffMax)
		end
		state.opening[key] = nil
		return { ok = false, reason = if orphaned then "cancelled" else "closing" }
	end
	state.opening[key] = nil
	return { ok = true, profile = session.profile }
end

function Open.load(state: State, key: string, asked: LoadOptions?): LoadResult
	assert(type(key) == "string" and #key > 0 and #key <= 50, "KeepBlox: a key is 1-50 characters")
	const clock = state.base.services.clock
	const thrown: { problem: any? } = { problem = nil }
	const options = guarded(asked, thrown)
	-- One deadline for the whole load: waiting for a release here, the import, the claim and a trade's
	-- settling all count against it, so the load answers within `loadTimeout`.
	const deadline = clock.now() + state.config.loadTimeout
	const waited = Settle.wait(state, clock, key, options and options.cancel, deadline)
	if thrown.problem ~= nil then
		error(thrown.problem, 0)
	elseif waited then
		return { ok = false, reason = waited }
	end
	if state.sessions[key] or state.opening[key] then
		return { ok = false, reason = "open" }
	end
	const asker = coroutine.running()
	state.opening[key] = asker
	return Apart.run(clock, function(problem: any)
		state.onError:fire(key, `a load failed after its caller was cancelled: {problem}`)
	end, function(): LoadResult
		const ok, result = pcall(open, state, key, options, deadline, asker)
		if not ok then
			-- A load that throws is over: its key must not stay marked as opening.
			state.opening[key] = nil
			error(result, 0)
		elseif thrown.problem ~= nil and not result.ok then
			error(thrown.problem, 0)
		end
		return result
	end)
end

return Open
