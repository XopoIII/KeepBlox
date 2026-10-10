--!strict
--- Taking over a key from a server that died (or was cut off) with the play it had not stored yet:
--- the snapshot its last beat left in MemoryStore (see Lease), when that is newer than the record.
---
--- A snapshot of a large profile holds only its edits since it was stored; they are applied to the record
--- claimed, when that is the data they were made against.
---
--- The snapshot is written at once, in one lock-guarded write, with what goes with it: the purchase
--- receipt ids granted into it and the messages processed into it, so neither is granted or processed
--- again. A write the data store refuses is tried again until the load's deadline: the write says the
--- same thing however often it lands. Only when none lands is the snapshot not used, and the play since
--- the data was last stored lost rather than a purchase granted twice.
const Call = require("./Call")
const Codec = require("./Codec")
const Lease = require("./Lease")
const Lock = require("./Lock")
const Record = require("./Record")
const Snapshots = require("./Snapshots")
const Spare = require("./Spare")
const Types = require("./Types")

const Recover = {}

--> The record `key` continues from: `record` as claimed, or the previous owner's newer snapshot of it
--> once stored. `loadCount` is this session's. And whether a newer snapshot may be left unstored that
--> a later try could still store: MemoryStore gave no answer, or the data store took no write.
function Recover.run(
	context: Types.Context,
	key: string,
	loadCount: number,
	record: any,
	previous: Lock.Previous?
): (any, boolean)
	if previous == nil or not Lease.available(context) then
		return record, false
	end
	const snapshot, answered = Lease.snapshot(context, previous.jobId, key, previous.loadCount, previous.snap)
	if snapshot == nil then
		return record, not answered
	end
	-- Edits apply only to the data they were made against (see Snapshots). A whole snapshot needs none
	-- of the stored data, so it is not lost with a record this server cannot unpack.
	const data = if snapshot.p == nil
		then snapshot.d
		else Snapshots.data(snapshot, Codec.unpack(context.services.codec, record.Data))
	if data == nil then
		context.report(key, "a newer snapshot was found but was made against other data; the stored data is used")
		return record, false
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
		data = data,
		release = false,
		receipts = receipts,
		consumed = consumed,
		schemaVersion = snapshot.v,
		snap = 0,
	}
	const clock = context.services.clock
	const config = context.config
	const deadline = context.deadline or clock.now() + config.loadTimeout
	local stored: any = nil
	local ok = false
	local delay = config.backoffMin
	local tries = 0
	while true do
		-- As a claim does: the first try waits for one request, later ones leave a reserve to saves.
		Spare.wait(context, if tries == 0 then 1 else Spare.RESERVE, deadline, context.closing)
		tries += 1
		ok = Call.run(
			clock,
			math.clamp(deadline - clock.now(), 1, config.callTimeout),
			context.dataStore.UpdateAsync,
			context.dataStore,
			key,
			function(value: any): any
				const written, result = Lock.save(value, context.identity, loadCount, payload, clock.time())
				stored = if result.kind == "saved" then result.record else nil
				return written
			end
		)
		-- A write that was answered settles it, stored or not (the key is no longer this session's).
		if ok or context.closing() or clock.now() + delay >= deadline then
			break
		end
		clock.wait(delay)
		delay = math.min(delay * 2, config.backoffMax)
	end
	if not ok or stored == nil then
		context.report(key, "a newer snapshot was found but could not be stored; the stored data is used")
		return record, not ok
	end
	return stored, false
end

return Recover
