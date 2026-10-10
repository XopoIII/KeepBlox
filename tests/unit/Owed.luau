--!strict
--- The note a load leaves in the record when it gives a key back without having stored its dead
--- owner's last beat, and the claim that reads it (src/Owed.luau, src/Lock.luau; issue 36). The scenes
--- are in tests/unit/LoadOwes.luau.
const Lock = require("@keepblox/Lock")
const Record = require("@keepblox/Record")
const Spec = require("../Spec")

const A: Record.Identity = { placeId = 1, jobId = "job-A", guid = "guid-A" }
const B: Record.Identity = { placeId = 1, jobId = "job-B", guid = "guid-B" }
const C: Record.Identity = { placeId = 1, jobId = "job-C", guid = "guid-C" }
const TEMPLATE = { coins = 0 }

-- "u_1" as B held it when it died: its first session, its data stored at snapshot 3.
const function dead(): any
	const record = Lock.claim(nil, B, TEMPLATE, 1000, false)
	return (Lock.save(record, B, 1, { data = { coins = 5 }, release = false, snap = 3 }, 1001))
end

-- The same key after A took it over and gave it back, with `owed` in the give-back.
const function givenBack(owed: boolean): (any, Lock.Previous)
	const record, claim = Lock.claim(dead(), A, TEMPLATE, 2000, false, { force = true })
	assert(claim.kind == "taken" and claim.previous, "A took the key from B")
	const payload: Lock.Payload = { data = nil, release = true, owed = if owed then claim.previous else nil }
	const freed, saved = Lock.save(Record.copy(record), A, claim.loadCount, payload, 2001)
	assert(saved.kind == "saved", "A gave the key back")
	return freed, claim.previous
end

Spec.test("Owed: a takeover names its previous owner, and a give-back can leave it as a note", function()
	const freed, previous = givenBack(true)
	Spec.equal(previous, { jobId = "job-B", loadCount = 1, snap = 3 })
	Spec.equal(freed.MetaData.ActiveSession, nil)
	Spec.equal(freed.MetaData.SessionLoadCount, 2)
	Spec.equal(freed.MetaData.KeepBlox.owed, { j = "job-B", c = 1, q = 3, at = 2 })
	-- Without it the record says nothing of B, as before.
	const plain = givenBack(false)
	Spec.equal(plain.MetaData.KeepBlox.owed, nil)
	Spec.equal(plain.MetaData.KeepBlox, { lease = 4, owner = "guid-A" })
end)

Spec.test("Owed: the next claim of the free key recovers from the owner the note names, and uses it up", function()
	const record, claim = Lock.claim(givenBack(true), C, TEMPLATE, 3000, false)
	assert(claim.kind == "taken", "C took the free key")
	Spec.equal(claim.previous, { jobId = "job-B", loadCount = 1, snap = 3 })
	Spec.equal(claim.loadCount, 3)
	Spec.equal(record.MetaData.KeepBlox.owed, nil, "the note is gone from what C writes")
	-- A key freed with no note has no previous owner.
	const _, plain = Lock.claim(givenBack(false), C, TEMPLATE, 3000, false)
	Spec.equal((plain :: any).previous, nil)
	-- The server that left the note may be the one to use it.
	const _, again = Lock.claim(givenBack(true), A, TEMPLATE, 3000, false)
	Spec.equal((again :: any).previous, { jobId = "job-B", loadCount = 1, snap = 3 })
end)

Spec.test("Owed: a note is void once any session has loaded the key since, and a claim still clears it", function()
	-- A server that does not know the note (ProfileStore, a KeepBlox before 0.6.10) loaded the key,
	-- played and released it: the load count moved, the note stayed.
	const stale = givenBack(true)
	stale.MetaData.SessionLoadCount = 3
	stale.Data = { coins = 9 }
	const record, claim = Lock.claim(stale, C, TEMPLATE, 3000, false)
	assert(claim.kind == "taken", "C took the free key")
	Spec.equal(claim.previous, nil, "the beat is older than the play since")
	Spec.equal(record.MetaData.KeepBlox.owed, nil)
	Spec.equal(record.Data, { coins = 9 })
	-- A note that is not one is no previous owner either.
	for index, garbage in
		{ "job-B", { j = 7, c = 1, q = 3, at = 2 }, { j = "job-B", c = "1", q = 3, at = 2 }, { j = "job-B", c = 1 } } :: { any }
	do
		const odd = givenBack(false)
		odd.MetaData.KeepBlox.owed = garbage
		const written, taken = Lock.claim(odd, C, TEMPLATE, 3000, false)
		Spec.equal((taken :: any).previous, nil, `garbage {index}`)
		Spec.equal(written.MetaData.KeepBlox.owed, nil, `garbage {index}`)
	end
	-- A note with no snapshot number counts from zero.
	const bare = givenBack(false)
	bare.MetaData.KeepBlox.owed = { j = "job-B", c = 1, at = 2 }
	const _, taken = Lock.claim(bare, C, TEMPLATE, 3000, false)
	Spec.equal((taken :: any).previous, { jobId = "job-B", loadCount = 1, snap = 0 })
end)

Spec.test("Owed: a key taken from a holder recovers from that holder, whatever note the record carries", function()
	-- Held by A again, which died in its turn, with a note of B still in the record (left there by a
	-- server that does not clear it).
	const held = Lock.claim(givenBack(false), A, TEMPLATE, 2500, false)
	held.MetaData.KeepBlox.owed = { j = "job-B", c = 1, q = 3, at = held.MetaData.SessionLoadCount }
	held.MetaData.KeepBlox.snap = 8
	const record, claim = Lock.claim(Record.copy(held), C, TEMPLATE, 3000, false, { force = true })
	assert(claim.kind == "taken", "C took the key from A")
	Spec.equal(claim.previous, { jobId = "job-A", loadCount = 3, snap = 8 })
	Spec.equal(record.MetaData.KeepBlox.owed, nil)
	-- A server claiming the key it already holds has no previous owner, and clears the note too.
	const own, mine = Lock.claim(Record.copy(held), A, TEMPLATE, 3000, false)
	Spec.equal((mine :: any).previous, nil)
	Spec.equal(own.MetaData.KeepBlox.owed, nil)
	-- A claim that only asks leaves the record's note alone: it takes nothing.
	const asked, busy = Lock.claim(Record.copy(held), C, TEMPLATE, 3000, false)
	Spec.equal(busy.kind, "busy")
	Spec.equal(asked.MetaData.KeepBlox.owed, { j = "job-B", c = 1, q = 3, at = 3 })
end)

Spec.test("Owed: a key this server holds is disowned by its load count only when both still match", function()
	const held, claim = Lock.claim(dead(), A, TEMPLATE, 2000, false, { force = true })
	assert(claim.kind == "taken", "A took the key")
	const freed = Lock.disown(Record.copy(held), A, 2100, 2)
	Spec.equal(freed and freed.MetaData.ActiveSession, nil)
	Spec.equal(freed.MetaData.SessionLoadCount, 2)
	Spec.equal(freed.MetaData.LastUpdate, 2100)
	Spec.equal(freed.Data, { coins = 5 })
	-- Any GUID of this server will do: the store that frees a stray key is not the load that took it.
	const other: Record.Identity = { placeId = 1, jobId = "job-A", guid = "guid-of-the-store" }
	Spec.equal(Lock.disown(Record.copy(held), other, 2100, 2) ~= nil, true)
	Spec.equal(Lock.disown(Record.copy(held), other, 2100), nil, "by GUID it is not that load's")
	-- Another load count, another server, a free key, a value that is no profile: nothing is written.
	Spec.equal(Lock.disown(Record.copy(held), A, 2100, 1), nil)
	Spec.equal(Lock.disown(Record.copy(held), A, 2100, 3), nil)
	Spec.equal(Lock.disown(Record.copy(held), C, 2100, 2), nil)
	Spec.equal(Lock.disown(Record.copy(freed), A, 2100, 2), nil)
	Spec.equal(Lock.disown("text", A, 2100, 2), nil)
	Spec.equal(Lock.disown(nil, A, 2100, 2), nil)
end)

return nil
