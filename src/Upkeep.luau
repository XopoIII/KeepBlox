--!strict
--- What a store does in the background: renewing its sessions, releasing them on shutdown, and
--- listening for the messages other servers send to a session.
const Lease = require("./Lease")
const Services = require("./Services")
const Session = require("./Session")

--> What the background work needs from its store.
export type Internals = {
	--> The store's context; its services can change once (Studio without access switches to memory).
	context: () -> Session.Context,
	sessions: { [string]: Session.Session },
	closing: () -> boolean,
}

export type Listener = { session: Session.Session?, connection: Services.Connection?, done: boolean }

const Upkeep = {}

-- Seconds before the shutdown deadline when releases still pending leave their data in a last beat.
const LAST_BEAT = 3

--> Beats this server's MemoryStore entry every `heartbeat` seconds, from the start (see Lease), and
--> hands over the sessions another server asked for there. `beating.ok` says whether newcomers may
--> trust the beat: only then does a session's record say so.
---
--> The trust is measured from when a beat was sent, not from when a call gives up (`callTimeout`): a
--> newcomer judges a beat that stands still for two beats dead, so an owner whose beats stop landing
--> withdraws the trust from its records after one and a half, before it could be taken for dead
--> (PaxosLease Revisited, arXiv 2609.14640: the holder must give up first). A takeover on the beat's
--> word lands only while the record still vouches for it (see Lock). Returns one beat, for a load
--> that must not wait for the loop's next one, and the check that notices the trust run out while a
--> beat hangs (the renewal loop runs it every second).
function Upkeep.beat(internals: Internals, beating: { ok: boolean, sentAt: number }): (() -> (), () -> ())
	const clock = internals.context().services.clock
	const function trusted(context: Session.Context, sentAt: number): boolean
		return clock.now() - sentAt <= 1.5 * context.config.heartbeat
	end
	const function once()
		const context = internals.context()
		if not Lease.available(context) then
			return
		end
		const sentAt = clock.now()
		const requested = Lease.beat(context, internals.sessions)
		-- A beat that landed too late to have been trusted still brings its requests, but no trust.
		if requested ~= nil and trusted(context, sentAt) then
			beating.sentAt = math.max(beating.sentAt, sentAt)
		end
		const landed = requested ~= nil and trusted(context, beating.sentAt)
		if landed and not beating.ok then
			-- The beat is back: sessions opened meanwhile tell newcomers so at their next write.
			for _, session in internals.sessions do
				session.saveSoon = true
			end
		end
		beating.ok = landed
		-- A profile no snapshot covers is written at `renewFallback`, so a crash loses no more than that.
		const soonest = clock.now() + context.config.renewFallback
		for _, session in internals.sessions do
			if not session.snapshotted and session.nextRenew > soonest then
				session.nextRenew = soonest
			end
		end
		for key, fence in requested or {} do
			const session = internals.sessions[key]
			if
				session
				and session.active
				and not session.releasing
				and (fence == true or fence == session.loadCount)
			then
				clock.spawn(Session.release, session.context, session, "handedOver")
			end
		end
	end
	clock.spawn(function()
		while not internals.closing() do
			once()
			clock.wait(internals.context().config.heartbeat)
		end
	end)
	-- A beat that hangs holds up the loop above: its sessions tell newcomers at their next write.
	const function check()
		if beating.ok and not trusted(internals.context(), beating.sentAt) then
			beating.ok = false
			for _, session in internals.sessions do
				session.snapshotted = false
				session.saveSoon = true
			end
		end
	end
	return once, check
end

--> Renews every session every `renew` seconds, and saves soon the ones that asked for it. The loop
--> waits while the server's data store budget is spent, so loads and releases are not starved.
--> `every` runs each second first (the beat's trust check).
function Upkeep.renew(internals: Internals, every: () -> ())
	const clock = internals.context().services.clock
	clock.spawn(function()
		while not internals.closing() do
			clock.wait(1)
			every()
			const context = internals.context()
			const dataStores = context.services.dataStores
			const now = clock.now()
			for _, session in internals.sessions do
				const due = now >= session.nextRenew
				if session.active and (due or session.saveSoon) and not session.serial:busy() then
					if
						dataStores:GetRequestBudgetForRequestType("StandardWrite") <= 0
						or dataStores:GetRequestBudgetForRequestType("StandardRead") <= 0
					then
						break
					end
					if due then
						session.nextRenew = now
							+ if session.snapshotted then context.config.renew else context.config.renewFallback
					end
					session.saveSoon = false
					clock.spawn(Session.save, session.context, session, true)
				end
			end
		end
	end)
end

--> On shutdown, releases every session in parallel, and waits for them within the deadline.
--> `close` marks the store closing first, so no new load starts. Returns the same closing, for
--> `store:close()` (tests, and games that close a store themselves).
function Upkeep.shutdown(internals: Internals, close: () -> ()): () -> ()
	const context = internals.context()
	const clock = context.services.clock
	const function closeAll()
		close()
		local pending = 0
		for _, session in internals.sessions do
			pending += 1
			clock.spawn(function()
				Session.release(session.context, session, "shutdown")
				pending -= 1
			end)
		end
		const started = clock.now()
		const deadline = context.config.shutdownDeadline
		local lastBeat = false
		while pending > 0 and clock.now() - started < deadline do
			-- Releases the budget could not land yet leave their data in one last beat, which the next
			-- server takes (see Lease, Recover). A release that lands after it stores the same snapshot
			-- number, so then the record wins.
			if not lastBeat and clock.now() - started >= deadline - LAST_BEAT and Lease.available(context) then
				lastBeat = true
				const left: { [string]: Session.Session } = {}
				for key, session in internals.sessions do
					if session.active then
						left[key] = session
					end
				end
				clock.spawn(Lease.beat, context, left, true)
			end
			clock.wait(0.1)
		end
	end
	context.services.bindToClose(closeAll)
	return closeAll
end

--> Listens on "PS_"..`guid` for requests to a session: `EndSession` hands it over, and a bare
--> `LoadCount` (someone sent a message) makes it save soon. It subscribes before the claim, so a
--> request that comes right after the key is taken is not missed. Subscribing can hang (as in Team
--> Test), so it never holds up the load.
function Upkeep.listen(services: Services.Services, guid: string, target: Listener)
	services.clock.spawn(function()
		const ok, connection = pcall(function()
			return services.messaging:SubscribeAsync(`PS_{guid}`, function(message: Services.Message)
				const data = message.Data
				const session = target.session
				if session == nil or type(data) ~= "table" or data.LoadCount ~= session.loadCount then
					return
				end
				if data.EndSession then
					Session.release(session.context, session, "handedOver")
				else
					session.saveSoon = true
				end
			end)
		end)
		if ok then
			if target.done then
				connection:Disconnect()
			else
				target.connection = connection
			end
		end
	end)
end

return Upkeep
