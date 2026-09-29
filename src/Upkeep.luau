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

--> Beats this server's MemoryStore entry every `heartbeat` seconds, from the start (see Lease), and
--> hands over the sessions another server asked for there. `beating.ok` says whether the last beat
--> landed: only then may a new session tell newcomers to trust the beat.
function Upkeep.beat(internals: Internals, beating: { ok: boolean })
	const clock = internals.context().services.clock
	clock.spawn(function()
		while not internals.closing() do
			const context = internals.context()
			if Lease.available(context) then
				const requested = Lease.beat(context)
				if requested ~= nil and not beating.ok then
					-- The beat is back: sessions opened meanwhile tell newcomers so at their next write.
					for _, session in internals.sessions do
						session.saveSoon = true
					end
				end
				beating.ok = requested ~= nil
				for _, key in requested or {} do
					const session = internals.sessions[key]
					if session and session.active and not session.releasing then
						clock.spawn(Session.release, session.context, session, "handedOver")
					end
				end
			end
			clock.wait(context.config.heartbeat)
		end
	end)
end

--> Renews every session every `renew` seconds, and saves soon the ones that asked for it. The loop
--> waits while the server's data store budget is spent, so loads and releases are not starved.
function Upkeep.renew(internals: Internals)
	const clock = internals.context().services.clock
	clock.spawn(function()
		while not internals.closing() do
			clock.wait(1)
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
						session.nextRenew = now + context.config.renew
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
		while pending > 0 and clock.now() - started < context.config.shutdownDeadline do
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
