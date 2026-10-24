--!strict
--- A schedule: jobs due at a time, kept in a data store, taken by whichever server sweeps first once
--- their time has come. For what must happen later whether or not anyone is in the game then: a
--- reminder to send, a reward to grant, a crop to ripen. One job a key.
---
---     const reminders = KeepBlox.schedule("Reminders")
---     reminders:put(`u_{userId}`, os.time() + 3600, { kind = "crop" })
---     -- on every server, every half minute or so:
---     reminders:sweep(function(key, job)
---         sendReminder(key, job.data)
---         return nil -- done; a job to keep it for later, false to leave it for another sweep
---     end)
---
--- Why not MemoryStore: a memory store's quota grows with the players in the game at once, while what
--- a game schedules for players who are away grows with all its players. A schedule costs data store
--- requests instead, from each server's own budget, and nothing is lost when no server runs.
---
--- `update` changes a key's job in one UpdateAsync, on the value stored at that moment, as a shared
--- store's update does (see Shared): `change` must not yield and may run more than once, and a change
--- whose call is tried again lands once (see Once). Due times are whole Unix seconds of the server's
--- clock (`os.time`). The keys whose time has come are read from an ordered data store beside the
--- jobs (see JobIndex); `sweep` takes each due job with a claim, so one server holds it at a time,
--- and runs it. A server that dies holding a claim, or a handler that outlasts it, leaves the job to
--- the next sweep once the claim expires: a handler should be safe to run again.
---
--- Use a data store of its own. In Studio, a place that cannot reach live data keeps the jobs in memory
--- and says so once through `onError` (see Studio).
const Call = require("./Call")
const Config = require("./Config")
const JobIndex = require("./JobIndex")
const JobRecord = require("./JobRecord")
const Once = require("./Once")
const Record = require("./Record")
const Report = require("./Report")
const Services = require("./Services")
const Signal = require("./Signal")
const Studio = require("./Studio")
const Sweep = require("./Sweep")
const Validate = require("./Validate")

export type Job = JobRecord.Job
export type Handled = Sweep.Handled
export type Swept = Sweep.Swept
export type SweepOptions = Sweep.Options

export type Options = {
	--> Seconds a server holds a job it took before another may take it. Default 120.
	claim: number?,
	--> Seconds a job is kept past its due time while no sweep finishes it; then it is dropped. Default
	--> a day.
	keep: number?,
	services: Services.Services?,
	config: Config.Overrides?,
	mock: (boolean | string)?,
}

export type Result =
	{ ok: true, job: Job? }
	| { ok: false, reason: "error" | "refused" | "foreign" | "failed", message: string? }

export type Schedule = {
	name: string,
	--> Fires `(key, message, kind)` for a problem worth logging: a job stored whose index could not be
	--> written (kind "schedule"), a handler that threw, and Studio without live data (kind "studio").
	onError: Signal.Signal<string, string, Report.ErrorKind>,
	--> The job `key` holds now (a copy), nil for none.
	read: (self: Schedule, key: string) -> Result,
	--> Changes `key`'s job in one UpdateAsync: `change` gets the job (a copy, nil for none) and returns
	--> the job to keep, or nil to remove it. Returns the job stored.
	update: (self: Schedule, key: string, change: (job: Job?) -> Job?) -> Result,
	--> Sets `key`'s job, replacing any.
	put: (self: Schedule, key: string, due: number, data: any) -> Result,
	--> Removes `key`'s job.
	remove: (self: Schedule, key: string) -> Result,
	--> Runs the jobs due now (see Sweep). Yields.
	sweep: (self: Schedule, handler: (key: string, job: Job) -> Handled, options: SweepOptions?) -> Swept,
}

const Schedule = {}

function Schedule.new(name: string, options: Options?): Schedule
	assert(type(name) == "string" and #name > 0, "KeepBlox: a schedule needs a name")
	const given: Options = options or {}
	const config = Config.resolve(given.config)
	const origin = given.services or require("./RobloxServices").build()
	const clock = origin.clock
	const onError: Signal.Signal<string, string, Report.ErrorKind> = Signal.new(clock.spawn)
	const report = function(key: string, message: string, kind: Report.ErrorKind)
		onError:fire(key, message, kind)
	end
	const chosen = Studio.choose(origin, name, if given.mock == true then "schedule" else given.mock, "live")
	const prepare = Studio.guard(chosen, name, report)
	const lifetime = config.loadTimeout + config.callTimeout

	-- The stores as Studio chose them, read at each call: they move to memory when Studio has no access.
	const function stores(): JobIndex.Stores
		return {
			dataStore = chosen.dataStore,
			index = chosen.services.dataStores:GetOrderedDataStore(`{name}_due`),
			clock = clock,
			timeout = config.callTimeout,
		}
	end

	-- A call retried with backoff until it answers or `loadTimeout` passes.
	const function retried(fn: () -> ...any): (boolean, ...any)
		const started = clock.now()
		local delay = config.backoffMin
		while true do
			const results = table.pack(Call.run(clock, config.callTimeout, fn))
			if results[1] or clock.now() - started > config.loadTimeout then
				return table.unpack(results, 1, results.n)
			end
			clock.wait(delay)
			delay = math.min(delay * 2, config.backoffMax)
		end
	end

	const function update(key: string, change: (job: Job?) -> Job?): Result
		assert(type(change) == "function", "KeepBlox: update needs a function")
		prepare()
		const id = origin.guid()
		const started, startedAt = clock.now(), clock.time()
		const keep = lifetime + Once.SKEW
		const ok, answer = retried(function(): any
			local outcome: Result = { ok = false, reason = "failed" }
			const guarded, broken = Call.guard(function(value: any): any
				const kind = JobRecord.classify(value)
				if kind == "foreign" then
					outcome = { ok = false, reason = "foreign" } :: Result
					return nil
				end
				const record: JobRecord.Stored = if kind == "job" then value else JobRecord.fresh()
				if Once.seen(record.applied, id) then
					outcome = { ok = true, job = JobRecord.job(record) } :: Result
					return nil
				elseif clock.now() - started > lifetime then
					outcome = { ok = false, reason = "failed", message = "the update ran out of time" } :: Result
					return nil
				end
				const changed, job = pcall(change, JobRecord.job(record))
				if not changed then
					outcome = { ok = false, reason = "error", message = tostring(job) } :: Result
					return nil
				end
				if job ~= nil then
					const due = if type(job) == "table" then JobRecord.second(job.due) else nil
					if due == nil then
						outcome =
							{ ok = false, reason = "refused", message = "a job's due is a time in seconds" } :: Result
						return nil
					end
					const data = Record.copy(job.data)
					const _, refusal = Validate.check(data, "data")
					if refusal then
						outcome = { ok = false, reason = "refused", message = refusal } :: Result
						return nil
					end
					record.due, record.data = due, data
				else
					record.due, record.data = nil, nil
				end
				record.version += 1
				record.applied = Once.note(record.applied, id, startedAt, clock.time(), keep)
				outcome = { ok = true, job = JobRecord.job(record) } :: Result
				return record
			end)
			stores().dataStore:UpdateAsync(key, guarded)
			const problem = broken()
			if problem then
				error(problem, 0)
			end
			return outcome
		end)
		if not ok then
			return { ok = false, reason = "failed", message = tostring(answer) }
		end
		const result: Result = answer
		const job = if result.ok then result.job else nil
		if job then
			-- The job is stored; the index must find it. Tried as long as a load would wait.
			const indexed = retried(function()
				assert(JobIndex.lower(stores(), key, job.due), "the index did not answer")
			end)
			if not indexed then
				report(
					key,
					"a job was stored but its index could not be written: it waits for the next change",
					"schedule"
				)
				return { ok = false, reason = "failed", message = "the job was stored but not indexed" }
			end
		end
		return result
	end

	return {
		name = name,
		onError = onError,
		read = function(_: Schedule, key: string): Result
			prepare()
			const ok, value = retried(function(): any
				return (stores().dataStore:GetAsync(key, false))
			end)
			if not ok then
				return { ok = false, reason = "failed", message = tostring(value) }
			end
			const kind = JobRecord.classify(value)
			if kind == "foreign" then
				return { ok = false, reason = "foreign" }
			end
			return { ok = true, job = if kind == "job" then JobRecord.job(value) else nil }
		end,
		update = function(_: Schedule, key: string, change: (job: Job?) -> Job?): Result
			return update(key, change)
		end,
		put = function(_: Schedule, key: string, due: number, data: any): Result
			return update(key, function(): Job?
				return { due = due, data = data }
			end)
		end,
		remove = function(_: Schedule, key: string): Result
			return update(key, function(): Job?
				return nil
			end)
		end,
		sweep = function(_: Schedule, handler: (key: string, job: Job) -> Handled, sweepOptions: SweepOptions?): Swept
			assert(type(handler) == "function", "KeepBlox: sweep needs a function")
			prepare()
			return Sweep.run(stores(), {
				services = chosen.services,
				guid = origin.guid,
				claim = given.claim or 120,
				keep = given.keep or 86400,
				report = report,
			}, handler, sweepOptions)
		end,
	}
end

return Schedule
