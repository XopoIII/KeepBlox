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
const Lock = require("./Lock")
const Session = require("./Session")

export type Failure = "cancelled" | "closing" | "timeout" | "foreign" | "outbid" | "inUse" | "legacyLocked"

export type Result = { ok: true, record: any, loadCount: number } | { ok: false, reason: Failure }

type Observed = {
	guid: string,
	loadCount: number,
	lease: number?,
	--> When this server last saw the lease move (or first saw this owner), by its own clock.
	since: number,
	--> When this server first asked this owner to hand over.
	askedAt: number,
}

const Claim = {}

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
function Claim.giveBack(context: Session.Context, key: string, loadCount: number)
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
	local steal = false
	local observed: Observed? = nil

	while true do
		if context.closing() then
			return { ok = false, reason = "closing" }
		elseif cancel and cancel() then
			return { ok = false, reason = "cancelled" }
		elseif clock.now() - started > config.loadTimeout then
			return { ok = false, reason = "timeout" }
		end

		local claim: Lock.Claim? = nil
		const ok, err = Call.run(
			clock,
			config.callTimeout,
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any, info: any): any
				const record, outcome = Lock.claim(value, context.identity, template, clock.time(), steal, mode, info)
				claim = outcome
				return record
			end
		)

		if not ok or claim == nil then
			context.report(key, `load attempt failed: {err}`)
		else
			const outcome = claim :: Lock.Claim
			if outcome.kind == "taken" then
				if context.closing() or (cancel and cancel()) then
					Claim.giveBack(context, key, outcome.loadCount)
					return { ok = false, reason = if context.closing() then "closing" else "cancelled" }
				end
				return { ok = true, record = outcome.record, loadCount = outcome.loadCount }
			elseif outcome.kind == "foreign" then
				quarantine(context, storeName, key, outcome.value)
				return { ok = false, reason = "foreign" }
			elseif outcome.kind == "outbid" then
				return { ok = false, reason = "outbid" }
			elseif outcome.kind == "legacyLocked" then
				-- The library being imported from still holds the key: wait for its release.
				if clock.now() - started + delay > config.loadTimeout then
					return { ok = false, reason = "legacyLocked" }
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
					watch =
						{ guid = guid, loadCount = owner.loadCount, lease = owner.lease, since = now, askedAt = now }
					observed = watch
				end
				const current = watch :: Observed
				const dead = if owner.lease == nil
					then owner.lastUpdate ~= nil and clock.time() - owner.lastUpdate > config.profileStoreDead
					else now - current.since >= config.death
				if dead then
					mode =
						{ quiet = true, expect = { guid = guid, loadCount = owner.loadCount, lease = owner.lease } } :: Lock.Mode
					continue
				elseif owner.lease == nil then
					return { ok = false, reason = "inUse" }
				end
				clock.wait(delay)
				delay = math.min(delay * 2, config.backoffMax)
				continue
			elseif watch == nil or watch.guid ~= guid or watch.loadCount ~= owner.loadCount then
				watch = { guid = guid, loadCount = owner.loadCount, lease = owner.lease, since = now, askedAt = now }
				observed = watch
				ask(context, owner)
			elseif owner.lease ~= watch.lease then
				watch.lease = owner.lease
				watch.since = now
			end
			const current = watch :: Observed
			if current.lease == nil then
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
