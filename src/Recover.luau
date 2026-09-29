--!strict
--- Taking over a key from a server that died (or was cut off) with the play it had not stored yet:
--- the snapshot its last beat left in MemoryStore (see Lease), when that is newer than the record.
---
--- The snapshot is written at once, in one lock-guarded write, with what goes with it: the purchase
--- receipt ids granted into it and the messages processed into it, so neither is granted or processed
--- again. If that write fails, the snapshot is not used: a few seconds of play are lost rather than a
--- purchase granted twice.
const Call = require("./Call")
const Lease = require("./Lease")
const Lock = require("./Lock")
const Record = require("./Record")
const Types = require("./Types")

const Recover = {}

--> The record `key` continues from: `record` as claimed, or the previous owner's newer snapshot of it
--> once stored. `loadCount` is this session's.
function Recover.run(context: Types.Context, key: string, loadCount: number, record: any, previous: Lock.Previous?): any
	if previous == nil or not Lease.available(context) then
		return record
	end
	const snapshot = Lease.snapshot(context, previous.jobId, key, previous.loadCount, previous.snap)
	if snapshot == nil then
		return record
	end
	const receipts = Record.receipts(record.MetaData)
	for _, id in snapshot.rc or {} do
		if not table.find(receipts, id) then
			table.insert(receipts, id)
		end
	end
	const consumed: { [number]: boolean } = {}
	for _, index in snapshot.m or {} do
		consumed[index] = true
	end
	const payload: Lock.Payload = {
		data = snapshot.d,
		release = false,
		receipts = receipts,
		consumed = consumed,
		schemaVersion = snapshot.v,
		snap = 0,
	}
	local stored: any = nil
	const ok = Call.run(
		context.services.clock,
		context.config.callTimeout,
		context.dataStore.UpdateAsync,
		context.dataStore,
		key,
		function(value: any): any
			const written, result =
				Lock.save(value, context.identity, loadCount, payload, context.services.clock.time())
			stored = if result.kind == "saved" then result.record else nil
			return written
		end
	)
	if not ok or stored == nil then
		context.report(key, "a newer snapshot was found but could not be stored; the stored data is used")
		return record
	end
	return stored
end

return Recover
