--!strict
--- A scheduled job as a schedule's data store keeps it (see Schedule): one record a key.
---
---     { KeepBlox = "job", version = 7, due = 1761300000, data = {...}, claim = {...}, applied = {...} }
---
--- `due` is when the job is due, in whole Unix seconds; a record without one holds no job (it was done
--- or removed), and keeps only its `version` and the ids of the calls that changed it. `version` grows
--- with every change, so a server that took a job can tell whether it was changed while it ran.
--- `claim` is `{ id, expires }`: the sweep that took the job, by a fresh id, and when its claim expires
--- (Unix seconds by that server's clock); an expired claim is no claim. `applied` holds the ids of
--- recent changes, so a retried change lands once (see Once).
const Record = require("./Record")

export type Job = { due: number, data: any }
export type Claim = { id: string, expires: number }

export type Stored = {
	KeepBlox: "job",
	version: number,
	due: number?,
	data: any,
	claim: Claim?,
	applied: any,
}

--> What a key of a schedule's data store holds: nothing yet, a job record (with a job or none), or
--> data that is not one.
export type Kind = "missing" | "job" | "foreign"

const JobRecord = {}

--> The latest second a job may be due by: values of an ordered data store are 64-bit integers, and a
--> due time past this one parks the index (see Schedule).
JobRecord.LATEST = 2 ^ 52

function JobRecord.classify(value: any): Kind
	if value == nil then
		return "missing"
	elseif type(value) == "table" and value.KeepBlox == "job" and type(value.version) == "number" then
		return "job"
	end
	return "foreign"
end

--> A stored record's job, a copy, or nil when it holds none.
function JobRecord.job(record: Stored?): Job?
	if record == nil or type(record.due) ~= "number" then
		return nil
	end
	return { due = record.due, data = Record.copy(record.data) }
end

--> A record holding nothing, before its first job.
function JobRecord.fresh(): Stored
	return { KeepBlox = "job", version = 0, due = nil, data = nil, claim = nil, applied = nil }
end

--> Whether the claim on `record` is held at `now` (Unix seconds) by anyone.
function JobRecord.claimed(record: Stored, now: number): boolean
	const claim = record.claim
	return type(claim) == "table" and type(claim.expires) == "number" and claim.expires > now
end

--> `due` as a schedule keeps it: a whole number of seconds, within an ordered data store's range. Nil
--> when it is not a number one can be.
function JobRecord.second(due: any): number?
	if type(due) ~= "number" or due ~= due or due < 0 or due >= JobRecord.LATEST then
		return nil
	end
	return math.floor(due)
end

return JobRecord
