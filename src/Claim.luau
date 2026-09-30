--!strict
--- Getting the lock on a key: the load side of the protocol.
---
--- 1. Claim. A free key, or one this server already holds, is taken at once.
--- 2. Ask. A held key gets our `ForceLoadSession`, and its owner is sent the same message ProfileStore
---    sends (`{LoadCount, EndSession = true}` on topic "PS_"..GUID). A live KeepBlox owner hands over
---    within a second on the message. Without the message, it hands over at its next renewal, when it
---    sees the request in the record.
--- 3. Wait. The key is polled with a backoff from `backoffMin` to `backoffMax` seconds.
--- 4. Take over, if the owner is gone:
---    - a KeepBlox owner is dead when its lease has not moved for `death` seconds. Only this server's
---      own clock measures that, so a skewed clock elsewhere cannot trigger a takeover;
---    - a ProfileStore owner is taken over by ProfileStore's own rules, `profileStoreSteal` seconds
---      after the first request, or when its LastUpdate is `profileStoreDead` old.
---    The takeover succeeds only while our request is still the latest: a third server asking since
---    then wins, and we report "outbid".
---
--- A value that is not a profile is never overwritten: it is copied to "<store>__quarantine" and the
--- load fails with "foreign".
const Call = require("./Call")
const Lease = require("./Lease")
const LetGo = require("./LetGo")
const Lock = require("./Lock")
const Session = require("./Session")

export type Failure = "cancelled" | "closing" | "timeout" | "foreign" | "outbid" | "inUse" | "legacyLocked"

export type Result =
	{ ok: true, record: any, loadCount: number, previous: Lock.Previous? }
	| { ok: false, reason: Failure }

type Observed = {
	guid: string,
	loadCount: number,
	lease: number?,
	--> When this server last saw the lease move (or first saw this owner), by its own clock.
	since: number,
	--> When this server first asked this owner to hand over.
	askedAt: number,
	--> What this server has seen of the owner's MemoryStore beat (see Lease).
	beat: Lease.Watch,
}

const Claim = {}

-- Seconds between tries while a live owner hands over, for the first HAND_OVER_QUICK seconds.
const HAND_OVER_POLL = 0.5
const HAND_OVER_QUICK = 15

const function ask(context: Session.Context, owner: Lock.Owner)
	const guid = owner.session[3]
	if type(guid) ~= "string" then
		return -- A ProfileService-era session has no GUID to message; polling will do.
	end
	context.services.clock.spawn(function()
		pcall(function()
			context.services.messaging:PublishAsync(`PS_{guid}`, { LoadCount = owner.loadCount, EndSession = true })
		end)
	end)
end

const function quarantine(context: Session.Context, storeName: string, key: string, value: any)
	context.report(key, "the stored value is not a profile; it was copied to quarantine and left untouched")
	pcall(function()
		const aside = context.services.dataStores:GetDataStore(`{storeName}__quarantine`)
		aside:SetAsync(key, { value = value, at = context.services.clock.time(), jobId = context.identity.jobId })
	end)
end

--> Lets go of a key this server has just taken but no longer wants (the player left, or shutdown).
Claim.giveBack = LetGo.giveBack

-- `mode` for a steal on the word of the owner's beat: it lands only while the record vouches for the
-- beat (see Lock).
const function onBeat(mode: Lock.Mode?): Lock.Mode
	const beat: Lock.Mode = if mode then table.clone(mode) else {}
	beat.byBeat = true
	return beat
end

--> Claims `key`, yielding until it is ours or the claim fails.
function Claim.open(
	context: Session.Context,
	storeName: string,
	key: string,
	template: { [any]: any },
	cancel: (() -> boolean)?,
	mode: Lock.Mode?
): Result
	const clock = context.services.clock
	const config = context.config
	const started = clock.now()
	local delay = config.backoffMin
	-- While a live owner is asked to hand over, the key is tried every half second: it is freed within a
	-- few seconds of the request, and a doubling backoff would leave it free for seconds before trying
	-- again. Past 15 s of that, the tries back off as usual, to spare the request budget.
	local handOverDelay = HAND_OVER_POLL
	local steal = false
	-- The steal is on the word of the owner's beat.
	local byBeat = false
	local observed: Observed? = nil
	-- A claim went unanswered, so it may hold the key: a failure must let go of it.
	local unsure = false
	const function fail(reason: Failure): Result
		if unsure then
			LetGo.disown(context, key)
		end
		return { ok = false, reason = reason }
	end

	while true do
		if context.closing() then
			return fail("closing")
		elseif cancel and cancel() then
			return fail("cancelled")
		elseif clock.now() - started > config.loadTimeout then
			return fail("timeout")
		end

		local claim: Lock.Claim? = nil
		const ok, err = Call.run(
			clock,
			config.callTimeout,
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any, info: any): any
				const record, outcome = Lock.claim(
					value,
					context.identity,
					template,
					clock.time(),
					steal,
					if steal and byBeat then onBeat(mode) else mode,
					info
				)
				claim = outcome
				return record
			end
		)

		if not ok or claim == nil then
			unsure = true
			context.report(key, `load attempt failed: {err}`)
		else
			const outcome = claim :: Lock.Claim
			if outcome.kind == "taken" then
				if context.closing() or (cancel and cancel()) then
					Claim.giveBack(context, key, outcome.loadCount)
					return { ok = false, reason = if context.closing() then "closing" else "cancelled" }
				end
				return { ok = true, record = outcome.record, loadCount = outcome.loadCount, previous = outcome.previous }
			elseif outcome.kind == "foreign" then
				quarantine(context, storeName, key, outcome.value)
				return { ok = false, reason = "foreign" }
			elseif outcome.kind == "outbid" then
				return { ok = false, reason = "outbid" }
			elseif outcome.kind == "legacyLocked" then
				-- The library being imported from still holds the key: wait for its release.
				if clock.now() - started + delay > config.loadTimeout then
					return fail("legacyLocked")
				end
				clock.wait(delay)
				delay = math.min(delay * 2, config.backoffMax)
				continue
			end

			-- Busy: another session holds the key.
			const owner = outcome.owner
			const now = clock.now()
			const guid = tostring(owner.session[3])
			local watch = observed
			if mode and mode.quiet then
				-- Never ask: fail while the owner lives, take the key only once it is proven dead.
				if
					watch ~= nil
					and (watch.guid ~= guid or watch.loadCount ~= owner.loadCount or owner.lease ~= watch.lease)
				then
					return { ok = false, reason = "inUse" }
				end
				if watch == nil then
					watch = {
						guid = guid,
						loadCount = owner.loadCount,
						lease = owner.lease,
						since = now,
						askedAt = now,
						beat = { asked = false, loadCount = owner.loadCount } :: Lease.Watch,
					}
					observed = watch
				end
				const current = watch :: Observed
				-- A beat that moves is a live owner; one that stopped is a dead one (see Lease).
				const verdict = if owner.memory
					then Lease.judge(context, tostring(owner.session[2]), key, current.beat, false)
					else "unknown"
				if verdict == "alive" then
					return { ok = false, reason = "inUse" }
				end
				const dead = verdict == "dead"
					or verdict == "unknown"
						and if owner.lease == nil
							then owner.lastUpdate ~= nil and clock.time() - owner.lastUpdate > config.profileStoreDead
							else now - current.since >= config.death
				if dead then
					const expect: Lock.Expected =
						{ guid = guid, loadCount = owner.loadCount, lease = owner.lease, byBeat = verdict == "dead" }
					mode = { quiet = true, expect = expect } :: Lock.Mode
					continue
				elseif owner.lease == nil then
					return { ok = false, reason = "inUse" }
				end
				clock.wait(delay)
				delay = math.min(delay * 2, config.backoffMax)
				continue
			elseif watch == nil or watch.guid ~= guid or watch.loadCount ~= owner.loadCount then
				watch = {
					guid = guid,
					loadCount = owner.loadCount,
					lease = owner.lease,
					since = now,
					askedAt = now,
					beat = { asked = false, loadCount = owner.loadCount } :: Lease.Watch,
				}
				observed = watch
				ask(context, owner)
			elseif owner.lease ~= watch.lease then
				watch.lease = owner.lease
				watch.since = now
			end
			const current = watch :: Observed
			-- The owner's MemoryStore beat, when it keeps one, decides (see Lease).
			const verdict = if owner.memory
				then Lease.judge(context, tostring(owner.session[2]), key, current.beat, true)
				else "unknown"
			byBeat = verdict ~= "unknown"
			if verdict == "dead" then
				steal = true
			elseif verdict ~= "unknown" then
				-- Watching a beat: the data store is tried every half second, and the beat looked at again
				-- the moment it could be judged dead, so a hand-over or the beat's end is caught as it comes.
				local waited = 0
				while waited < handOverDelay and not context.closing() and not (cancel and cancel()) do
					waited += clock.wait(math.min(Lease.nextLook(context, current.beat), handOverDelay - waited))
					if Lease.judge(context, tostring(owner.session[2]), key, current.beat, true) == "dead" then
						steal = true
						break
					end
				end
				if not steal and clock.now() - started > HAND_OVER_QUICK then
					handOverDelay = math.min(handOverDelay * 2, config.backoffMax)
				end
				continue
			elseif current.lease == nil then
				const stale = owner.lastUpdate ~= nil and clock.time() - owner.lastUpdate > config.profileStoreDead
				steal = stale or now - current.askedAt >= config.profileStoreSteal
			else
				steal = now - current.since >= config.death
			end
			if steal then
				continue
			end
		end
		clock.wait(delay)
		delay = math.min(delay * 2, config.backoffMax)
	end
end

return Claim
