--!strict
--- One open session: its writes (renewals, saves, the release), one at a time.
---
--- Every write goes through `Lock.save`, so it lands only while this session still owns the key. A
--- write that finds the key owned elsewhere ends the session at once: it is marked lost, its data
--- is frozen, and the game is told. That is how a lost session stops trades on a stale copy
--- (guarantee 6).
---
--- The data is checked before every write. Data that cannot be stored is not written; the lease is
--- still renewed and the last good save stays. So one bad value never blocks the session, its
--- hand-over or its release (the "poison" scenario), and the error names the value's path.
const Call = require("./Call")
const Config = require("./Config")
const Lock = require("./Lock")
const Profile = require("./Profile")
const Record = require("./Record")
const Serial = require("./Serial")
const Services = require("./Services")
const Validate = require("./Validate")

export type Context = {
	services: Services.Services,
	config: Config.Config,
	dataStore: Services.DataStore,
	identity: Record.Identity,
	--> Reports a problem with a key; the store turns it into its `onError` signal.
	report: (key: string, message: string) -> (),
	--> True once the server began shutting down.
	closing: () -> boolean,
	--> Called once when a session ends, so the store can forget it.
	forget: (session: Session) -> (),
}

export type Session = {
	key: string,
	loadCount: number,
	profile: Profile.Profile,
	--> The context this session writes with: the store's, with this session's own identity.
	context: Context,
	active: boolean,
	--> True from the moment a release begins: the data is frozen then, so the final save holds every
	--> change the game made.
	releasing: boolean,
	--> The canonical text of the data as last stored.
	storedText: string,
	storedSize: number,
	lastDataWrite: number,
	nextRenew: number,
	serial: Serial.Serial,
	--> The last validation problem reported, so it is not reported on every renewal.
	lastProblem: string?,
	--> The hand-over subscription, set up before the claim; `done` once the session ended.
	listener: { session: Session?, connection: Services.Connection?, done: boolean },
}

const Session = {}

--> Ends `session` for `reason`: it stops writing, its data is frozen, and the game is told.
function Session.finish(context: Context, session: Session, reason: Profile.EndReason)
	if not session.active then
		return
	end
	session.active = false
	session.listener.done = true
	if session.listener.connection then
		session.listener.connection:Disconnect()
		session.listener.connection = nil
	end
	Profile.freeze(session.profile.Data)
	context.forget(session)
	session.profile.onEnded:fire(reason)
end

-- One write, inside the session's serial lane. Returns whether it was stored.
const function write(
	context: Context,
	session: Session,
	release: boolean,
	reason: Profile.EndReason,
	automatic: boolean
): boolean
	if not session.active then
		return false
	end
	const clock = context.services.clock
	const profile = session.profile
	if release then
		session.releasing = true
		Profile.freeze(profile.Data)
	end
	const encoded, problem = Validate.check(profile.Data, "Data")
	local data: any = nil
	if encoded == nil then
		if problem ~= session.lastProblem then
			session.lastProblem = problem
			context.report(session.key, `not saved: {problem}`)
		end
	elseif encoded.text ~= session.storedText then
		session.lastProblem = nil
		-- A large profile writes less often, to stay inside the key's write throughput.
		const spacing = encoded.size * 60 / context.config.writeBytesPerMinute
		if not automatic or clock.now() - session.lastDataWrite >= spacing then
			data = Record.copy(profile.Data)
		end
	end
	const payload: Lock.Payload = {
		data = data,
		userIds = table.clone(profile.UserIds),
		robloxMetaData = Record.copy(profile.RobloxMetaData),
		release = release,
	}
	local outcome: Lock.Save? = nil
	const ok, err = Call.run(
		clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		session.key,
		function(value: any): any
			const record, result = Lock.save(value, context.identity, session.loadCount, payload, clock.time())
			outcome = result
			return record
		end
	)
	if not ok then
		context.report(session.key, `save failed: {err}`)
		return false
	end
	const result = outcome :: Lock.Save
	if result.kind == "lost" then
		Session.finish(context, session, "lost")
		return false
	end
	if data ~= nil and encoded then
		session.storedText = encoded.text
		session.storedSize = encoded.size
		session.lastDataWrite = clock.now()
	end
	profile.LastSavedData = Record.copy(result.record.Data)
	profile.onSaved:fire(Record.copy(result.record.Data))
	if release then
		Session.finish(context, session, reason)
	elseif result.handOver then
		-- Another server asked for the key: hand it over now, with a final save.
		clock.spawn(Session.release, context, session, "handedOver")
	end
	return true
end

--> Saves now (renewing the lease). Returns whether the save was stored. An `automatic` save (a
--> renewal) may leave changed data for later, to keep a large profile inside the key's write throughput.
function Session.save(context: Context, session: Session, automatic: boolean?): boolean
	if not session.active then
		return false
	end
	return session.serial:run(write, context, session, false, "released", automatic == true)
end

--> Ends the session with a final save, retrying until it is stored, the key turns out to be owned
--> elsewhere, or shutdown runs out of time.
function Session.release(context: Context, session: Session, reason: Profile.EndReason)
	const clock = context.services.clock
	const config = context.config
	local delay = config.backoffMin
	while session.active do
		if session.serial:run(write, context, session, true, reason, false) or not session.active then
			return
		end
		clock.wait(delay)
		delay = math.min(delay * 2, config.backoffMax)
	end
end

return Session
