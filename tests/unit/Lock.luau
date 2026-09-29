--!strict
const Lock = require("@keepblox/Lock")
const Record = require("@keepblox/Record")
const Spec = require("../Spec")

const HERE: Record.Identity = { placeId = 1, jobId = "job-A", guid = "guid-A" }
const THERE: Record.Identity = { placeId = 1, jobId = "job-B", guid = "guid-B" }
const THIRD: Record.Identity = { placeId = 1, jobId = "job-C", guid = "guid-C" }
const TEMPLATE = { coins = 0 }

const function claimed(value: any, identity: Record.Identity, steal: boolean?): (any, Lock.Claim)
	return Lock.claim(value, identity, TEMPLATE, 1000, steal == true)
end

Spec.test("Lock: a missing key becomes a new record this session owns", function()
	const record, claim = claimed(nil, HERE)
	Spec.equal(claim.kind, "taken")
	Spec.equal((claim :: any).loadCount, 1)
	Spec.equal(record.Data, { coins = 0 })
	Spec.equal(record.MetaData.ActiveSession, { 1, "job-A", "guid-A" })
	Spec.equal(record.MetaData.KeepBlox, { lease = 1, owner = "guid-A" })
	Spec.equal(record.MetaData.LastUpdate, 1000)
	Spec.equal(record.GlobalUpdates, { 0, {} })
	Spec.equal(Record.classify(record), "profile")
end)

Spec.test("Lock: messages sent before the first session are kept", function()
	const record = claimed({ GlobalUpdates = { 2, { { 2, "hi" } } } }, HERE)
	Spec.equal(record.GlobalUpdates, { 2, { { 2, "hi" } } })
end)

Spec.test("Lock: a foreign value is never overwritten", function()
	for _, value in { "text", 5, { Data = "not a table" }, { anything = true } } do
		const record, claim = claimed(value, HERE)
		Spec.equal(record, nil)
		Spec.equal(claim.kind, "foreign")
	end
end)

Spec.test("Lock: a held key gets a hand-over request; the owner's lease is reported", function()
	const held = claimed(nil, THERE)
	const record, claim = claimed(held, HERE)
	Spec.equal(claim.kind, "busy")
	const owner = (claim :: any).owner
	Spec.equal(owner.session, { 1, "job-B", "guid-B" })
	Spec.equal(owner.lease, 1)
	Spec.equal(owner.loadCount, 1)
	Spec.equal(record.MetaData.ForceLoadSession, { 1, "job-A" })
	Spec.equal(record.MetaData.ActiveSession, { 1, "job-B", "guid-B" })
end)

Spec.test("Lock: a ProfileStore owner reports no lease", function()
	const held = claimed(nil, THERE)
	held.MetaData.KeepBlox = nil
	const _, claim = claimed(held, HERE)
	Spec.equal((claim :: any).owner.lease, nil)
end)

Spec.test("Lock: steal succeeds only while the hand-over request is still ours", function()
	const held = claimed(claimed(nil, THERE), HERE)
	const stolen, claim = claimed(Record.copy(held), HERE, true)
	Spec.equal(claim.kind, "taken")
	Spec.equal((claim :: any).loadCount, 2)
	Spec.equal(stolen.MetaData.ActiveSession, { 1, "job-A", "guid-A" })
	Spec.equal(stolen.MetaData.ForceLoadSession, nil)
	const outbid = claimed(held, THIRD)
	const none, lost = claimed(outbid, HERE, true)
	Spec.equal(none, nil)
	Spec.equal(lost.kind, "outbid")
end)

Spec.test("Lock: the owner saves, bumps its lease, and learns of a hand-over request", function()
	const owned = claimed(nil, HERE)
	const saved, result = Lock.save(owned, HERE, 1, { data = { coins = 7 }, release = false }, 1010)
	Spec.equal(result.kind, "saved")
	Spec.equal((result :: any).handOver, false)
	Spec.equal(saved.Data, { coins = 7 })
	Spec.equal(saved.MetaData.KeepBlox.lease, 2)
	Spec.equal(saved.MetaData.LastUpdate, 1010)
	const asked = claimed(saved, THERE)
	const _, second = Lock.save(asked, HERE, 1, { data = nil, release = false }, 1020)
	Spec.equal((second :: any).handOver, true)
end)

Spec.test("Lock: a renewal keeps the stored data; a release clears the session", function()
	const owned = claimed(nil, HERE)
	owned.Data = { coins = 3 }
	const renewed = Lock.save(owned, HERE, 1, { data = nil, release = false }, 1010)
	Spec.equal(renewed.Data, { coins = 3 })
	const released = Lock.save(renewed, HERE, 1, { data = { coins = 4 }, release = true }, 1020)
	Spec.equal(released.MetaData.ActiveSession, nil)
	Spec.equal(released.Data, { coins = 4 })
end)

Spec.test("Lock: a session that no longer owns the key writes nothing", function()
	const owned = claimed(nil, HERE)
	const stale, result = Lock.save(owned, HERE, 7, { data = { coins = 1 }, release = false }, 1010)
	Spec.equal(stale, nil)
	Spec.equal(result.kind, "lost")
	const taken = claimed(claimed(claimed(nil, HERE), THERE), THERE, true)
	const none, lost = Lock.save(taken, HERE, 1, { data = { coins = 1 }, release = false }, 1010)
	Spec.equal(none, nil)
	Spec.equal((lost :: any).owner, { 1, "job-B", "guid-B" })
end)

Spec.test("Lock: disown frees the key only for the very load that holds it", function()
	const record = claimed(nil, HERE)
	-- Another load on the same server, another server, and a value that is not a profile: nothing.
	Spec.equal(Lock.disown(table.clone(record), { placeId = 1, jobId = "job-A", guid = "guid-A2" }, 1100), nil)
	Spec.equal(Lock.disown(table.clone(record), THERE, 1100), nil)
	Spec.equal(Lock.disown("text", HERE, 1100), nil)
	const freed = Lock.disown(record, HERE, 1100)
	Spec.equal(freed.MetaData.ActiveSession, nil)
	Spec.equal(freed.MetaData.LastUpdate, 1100)
	Spec.equal(freed.MetaData.KeepBlox, { lease = 2, owner = "guid-A" })
	Spec.equal(Lock.disown(freed, HERE, 1200), nil)
end)

return nil
