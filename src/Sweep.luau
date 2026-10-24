--!strict
--- One sweep of a schedule (see Schedule): the jobs due now, each taken with a claim and run once.
---
--- The keys whose second has come are read from the index, earliest first, `limit` of them. Each is
--- claimed in one UpdateAsync of its record: a job due, unclaimed or with an expired claim, gets this
--- sweep's claim, a fresh id, until `claim` seconds from now. Only then is the handler called, outside
--- any transform, so it may yield. What it answers is stored by one more UpdateAsync, and only while
--- the claim is still this sweep's and the job unchanged since (its `version`): a game's change made
--- meanwhile wins, and the job is left for a later sweep with the claim taken off.
---
--- - nil: done. The job is removed and its index entry parked.
--- - a job: kept, with its new due time and data, and the claim taken off.
--- - false: left as it is for a later sweep, the claim taken off.
---
--- A handler that throws leaves the job as false does, and is reported. A job no sweep finished for
--- `keep` seconds past its due time is dropped when next found, and counted. A key the index holds early,
--- or without a job, has its index entry settled (see JobIndex). Nothing is retried within a sweep: what
--- fails is left to the next one.
---
--- A sweep spends this server's data store budget: one ordered list request, and per job up to two
--- standard writes and an ordered write. It reads no more keys once fewer than `reserve` standard
--- writes are left in this server's budget, so saves always have theirs.
const Call = require("./Call")
const JobIndex = require("./JobIndex")
const JobRecord = require("./JobRecord")
const Record = require("./Record")
const Report = require("./Report")
const Services = require("./Services")

--> What a handler answers: nil (done), a job to keep, or false to leave it.
export type Handled = JobRecord.Job | false | nil

export type Options = {
	--> How many due keys one sweep reads at most. Default 50, at most 100 (a page).
	limit: number?,
	--> Standard writes left in the server's budget below which the sweep stops. Default 20.
	reserve: number?,
}

--> What one sweep did, by key: `done`, `kept` and `left` by the handler's answer, `failed` when the
--> handler threw or a call did not answer, `dropped` past `keep`, `busy` claimed by another server, and
--> `early` an index entry moved to its job's later time or parked for no job.
export type Swept = {
	done: number,
	kept: number,
	left: number,
	failed: number,
	dropped: number,
	busy: number,
	early: number,
}

export type Context = {
	services: Services.Services,
	guid: () -> string,
	claim: number,
	keep: number,
	report: Report.Report,
}

type Taken = "taken" | "busy" | "early" | "dropped" | "dead" | "foreign"

const Sweep = {}

function Sweep.run(
	stores: JobIndex.Stores,
	context: Context,
	handler: (key: string, job: JobRecord.Job) -> Handled,
	options: Options?
): Swept
	const clock = stores.clock
	const given: Options = options or {}
	const limit = math.clamp(math.floor(given.limit or 50), 1, 100)
	const reserve = given.reserve or 20
	const swept: Swept = { done = 0, kept = 0, left = 0, failed = 0, dropped = 0, busy = 0, early = 0 }
	const dataStores = context.services.dataStores
	if dataStores:GetRequestBudgetForRequestType("OrderedList") <= 0 then
		return swept
	end
	const now = clock.time()
	const listed, page = Call.run(clock, stores.timeout, function(): { Services.SortedEntry }
		return stores.index:GetSortedAsync(true, limit, nil, now):GetCurrentPage()
	end)
	if not listed then
		return swept
	end
	for _, entry in page :: { Services.SortedEntry } do
		if dataStores:GetRequestBudgetForRequestType("StandardWrite") < reserve then
			break
		end
		const key, seen = entry.key, entry.value
		const claimId = context.guid()
		local taken: Taken = "dead"
		local job: JobRecord.Job? = nil
		local version, later = 0, 0
		const asked = Call.update(clock, stores.timeout, stores.dataStore, key, function(value: any): any
			const kind = JobRecord.classify(value)
			if kind ~= "job" then
				taken = if kind == "foreign" then "foreign" else "dead"
				return nil
			end
			const record: JobRecord.Stored = value
			const due = JobRecord.second(record.due)
			if due == nil then
				taken = "dead"
				return nil
			elseif due > now then
				taken, later = "early", due
				return nil
			elseif JobRecord.claimed(record, now) then
				taken = "busy"
				return nil
			elseif now - due > context.keep then
				taken = "dropped"
				record.due, record.data, record.claim = nil, nil, nil
				record.version += 1
				return record
			end
			taken, version = "taken", record.version
			job = { due = due, data = Record.copy(record.data) }
			record.claim = { id = claimId, expires = now + context.claim }
			return record
		end)
		if not asked then
			swept.failed += 1
		elseif taken == "busy" then
			swept.busy += 1
		elseif taken == "early" then
			swept.early += 1
			JobIndex.settle(stores, key, seen, later)
		elseif taken == "dead" then
			swept.early += 1
			JobIndex.settle(stores, key, seen, JobIndex.PARKED)
		elseif taken == "dropped" then
			swept.dropped += 1
			JobIndex.settle(stores, key, seen, JobIndex.PARKED)
		elseif taken == "taken" then
			Sweep.finish(stores, context, key, seen, claimId, version, job :: JobRecord.Job, handler, swept)
		end
	end
	return swept
end

--> Runs `job`, which this sweep claimed by `claimId` at `version`, and stores what the handler answers.
function Sweep.finish(
	stores: JobIndex.Stores,
	context: Context,
	key: string,
	seen: number,
	claimId: string,
	version: number,
	job: JobRecord.Job,
	handler: (key: string, job: JobRecord.Job) -> Handled,
	swept: Swept
)
	const ran, answer = pcall(handler, key, job)
	if not ran then
		context.report(key, `a scheduled job's handler failed: {tostring(answer)}`, "schedule")
	end
	local kept: JobRecord.Job? = nil
	local outcome: "done" | "kept" | "left" | "failed" = "left"
	if not ran then
		outcome = "failed"
	elseif answer == nil then
		outcome = "done"
	elseif type(answer) == "table" then
		const due = JobRecord.second(answer.due)
		if due then
			kept, outcome = { due = due, data = Record.copy(answer.data) }, "kept"
		end
	end
	local landed = false
	const stored = Call.update(stores.clock, stores.timeout, stores.dataStore, key, function(value: any): any
		landed = false
		if JobRecord.classify(value) ~= "job" then
			return nil
		end
		const record: JobRecord.Stored = value
		const claim = record.claim
		if type(claim) ~= "table" or claim.id ~= claimId then
			return nil
		end
		record.claim = nil
		if record.version == version and (outcome == "done" or outcome == "kept") then
			record.due = if kept then kept.due else nil
			record.data = if kept then kept.data else nil
			record.version += 1
			landed = true
		end
		return record
	end)
	if not stored then
		swept.failed += 1
		return
	end
	if outcome == "failed" then
		swept.failed += 1
	elseif outcome == "left" or not landed then
		swept.left += 1
	elseif outcome == "done" then
		swept.done += 1
		JobIndex.settle(stores, key, seen, JobIndex.PARKED)
	else
		swept.kept += 1
		JobIndex.settle(stores, key, seen, (kept :: JobRecord.Job).due)
	end
end

return Sweep
