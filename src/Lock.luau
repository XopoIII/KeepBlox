--!strict
--- The lock, as pure `UpdateAsync` transforms: every decision is made from the stored record alone,
--- inside the transform, so it holds however calls interleave and whatever the local clock says.
---
--- - `claim` takes a free key, or one this server already holds. It asks the owner of a held key to
---   hand it over by writing `ForceLoadSession`. With `steal`, it takes the key only if that request
---   is still ours (a third server asking since then wins, as in ProfileStore).
--- - `force` takes the key from whoever holds it, at once (ProfileStore's `Steal = true`).
--- - `quiet` never asks: a held key is left as it is, unless the caller proves its owner dead.
--- - `save` writes only while `ActiveSession` is this server and `SessionLoadCount` is this session's.
---   Otherwise it writes nothing and reports the session lost. Every save bumps our lease and
---   `LastUpdate`, and reports another server's pending `ForceLoadSession`, so the owner hands over.
--- - `disown` lets go of a key a claim may have taken without learning it did (its answer was lost),
---   and only if that very claim holds it; or of one this server holds at a given load count.
---
--- A transform returns the record to write, or nil to write nothing, plus an outcome for the caller.
--- The engine may run it more than once; the last run's outcome is the one that counts. A call that
--- failed or timed out may have landed, and may land late (see Once). So a claim that finds the key
--- held by its own load writes nothing and answers as that load's claim did; one that finds the key
--- let go by its own load takes nothing; and a save whose stamp is not above the stored one writes
--- nothing, so a late save never puts older data over newer.
const LockTypes = require("./LockTypes")
const Messages = require("./Messages")
const Once = require("./Once")
const Owed = require("./Owed")
const Record = require("./Record")

export type Owner = LockTypes.Owner
export type Mode = LockTypes.Mode
export type Expected = LockTypes.Expected
export type Previous = LockTypes.Previous
export type Payload = LockTypes.Payload

--> A key this session now holds. `lastSavedAt` is the record's LastUpdate as the claim found it, before
--> the claim's own write replaced it: 0 for a key that held no profile, or no number there.
export type Taken = { kind: "taken", loadCount: number, record: any, previous: Previous?, lastSavedAt: number }

export type Claim =
	Taken
	| { kind: "busy", owner: Owner }
	| { kind: "outbid" }
	| { kind: "foreign", value: any }
	| { kind: "legacyLocked" }

export type Save =
	{ kind: "saved", handOver: boolean, record: any, messages: { Messages.Entry } }
	| { kind: "lost", owner: Record.Session? }

const Lock = {}

const function take(record: any, identity: Record.Identity, now: number, mode: Mode?): Claim
	const meta = record.MetaData
	const previous = Owed.previous(meta, identity)
	meta.ActiveSession = { identity.placeId, identity.jobId, identity.guid }
	meta.ForceLoadSession = nil
	meta.SessionLoadCount = (meta.SessionLoadCount or 0) + 1
	meta.LastUpdate = now
	const ours = Record.ours(meta)
	ours.owner = identity.guid
	ours.lease += 1
	ours.memory = if mode and mode.memory then true else nil
	ours.snap = nil
	ours.fence = nil
	Owed.took(meta, previous)
	record.WasOverwritten = false
	return { kind = "taken", loadCount = meta.SessionLoadCount, record = record, previous = previous, lastSavedAt = 0 }
end

const function decide(
	value: any,
	identity: Record.Identity,
	template: { [any]: any },
	now: number,
	steal: boolean,
	mode: Mode?,
	info: any?
): (any?, Claim)
	const kind = Record.classify(value)
	if kind == "foreign" then
		const adopt = mode and mode.adopt
		const found = if adopt then adopt(value, info, now) else nil
		if found and found.kind == "data" then
			const record = Record.fresh(found.data, now, nil)
			record.UserIds = table.clone(found.userIds or {})
			Record.ours(record.MetaData).importedFrom = (mode :: Mode).imported
			return record, take(record, identity, now, mode)
		elseif found and found.kind == "locked" then
			return nil, { kind = "legacyLocked" }
		end
		return nil, { kind = "foreign", value = value }
	end
	const record = if kind == "profile" then value else Record.fresh(template, now, value and value.GlobalUpdates)
	if kind ~= "profile" and mode then
		if mode.fromImport then
			Record.ours(record.MetaData).importedFrom = mode.imported
			record.UserIds = table.clone(mode.userIds or {})
		elseif mode.version then
			Record.ours(record.MetaData).schemaVersion = mode.version
		end
	end
	const meta = record.MetaData
	const active = meta.ActiveSession
	const mine = identity.guid ~= "" and Record.ours(meta).owner == identity.guid
	if mine and Record.isHere(active, identity) and active[3] == identity.guid then
		-- This very load holds the key: an earlier try of its claim landed unanswered.
		const loadCount = meta.SessionLoadCount or 0
		return nil,
			{ kind = "taken", loadCount = loadCount, record = record, previous = Owed.again(meta), lastSavedAt = 0 }
	elseif mine and active == nil then
		-- This very load held the key and let it go: a try of its claim that lands late takes nothing.
		return nil, { kind = "outbid" }
	elseif active == nil or Record.isHere(active, identity) then
		const claim = take(record, identity, now, mode)
		return record, claim
	end

	const ours = Record.ours(meta)
	const request = meta.ForceLoadSession
	const owner: Owner = {
		session = active,
		lease = if ours.owner ~= nil and ours.owner == active[3] then ours.lease else nil,
		lastUpdate = meta.LastUpdate,
		loadCount = meta.SessionLoadCount or 0,
		memory = ours.memory == true and ours.owner == active[3],
	}
	if mode and mode.force then
		return record, take(record, identity, now, mode)
	end
	if mode and mode.quiet then
		const expect = mode.expect
		if
			expect
			and expect.guid == tostring(active[3])
			and expect.loadCount == owner.loadCount
			and expect.lease == owner.lease
			and (not expect.byBeat or owner.memory)
		then
			return record, take(record, identity, now, mode)
		end
		return nil, { kind = "busy", owner = owner }
	end
	if steal then
		if mode and mode.byBeat and not owner.memory then
			return nil, { kind = "busy", owner = owner }
		elseif Record.isHere(request, identity) then
			const claim = take(record, identity, now, mode)
			return record, claim
		end
		return nil, { kind = "outbid" }
	end
	meta.ForceLoadSession = { identity.placeId, identity.jobId }
	return record, { kind = "busy", owner = owner }
end

--> The claim transform. `now` is this server's os.time(), stored as LastUpdate for ProfileStore.
function Lock.claim(
	value: any,
	identity: Record.Identity,
	template: { [any]: any },
	now: number,
	steal: boolean,
	mode: Mode?,
	info: any?
): (any?, Claim)
	-- Read before `take` writes over it. Imported data has no such time: its record is made here.
	const last = if Record.classify(value) == "profile" then value.MetaData.LastUpdate else nil
	const record, claim = decide(value, identity, template, now, steal, mode, info)
	if claim.kind == "taken" and type(last) == "number" then
		claim.lastSavedAt = last
	end
	return record, claim
end

--> The save transform for the session `loadCount` of this server.
function Lock.save(
	value: any,
	identity: Record.Identity,
	loadCount: number,
	payload: Payload,
	now: number
): (any?, Save)
	if Record.classify(value) ~= "profile" then
		return nil, { kind = "lost", owner = nil }
	end
	const meta = value.MetaData
	const active = meta.ActiveSession
	if not Record.isHere(active, identity) or meta.SessionLoadCount ~= loadCount then
		return nil, { kind = "lost", owner = active }
	elseif not Once.fence(Record.ours(meta), loadCount, payload.stamp) then
		const handOver = meta.ForceLoadSession ~= nil and not Record.isHere(meta.ForceLoadSession, identity)
		return nil, { kind = "saved", handOver = handOver, record = value, messages = Messages.list(value) }
	end
	Record.ours(meta).from = nil
	if payload.data ~= nil then
		value.Data = payload.data
	end
	if payload.consumed ~= nil then
		Messages.consume(value, payload.consumed)
	end
	if payload.receipts ~= nil then
		Record.ours(meta).receipts = payload.receipts
	end
	if payload.schemaVersion ~= nil then
		Record.ours(meta).schemaVersion = payload.schemaVersion
	end
	if payload.snap ~= nil then
		Record.ours(meta).snap = payload.snap
	end
	if payload.memory ~= nil then
		Record.ours(meta).memory = if payload.memory then true else nil
	end
	if payload.owed ~= nil then
		Owed.leave(meta, payload.owed)
	end
	if payload.journal ~= nil then
		Record.ours(meta).trade = if payload.journal == false then nil else payload.journal
	end
	if payload.userIds ~= nil then
		value.UserIds = payload.userIds
	end
	if payload.robloxMetaData ~= nil then
		value.RobloxMetaData = payload.robloxMetaData
	end
	meta.LastUpdate = now
	const ours = Record.ours(meta)
	ours.owner = identity.guid
	ours.lease += 1
	const request = meta.ForceLoadSession
	const handOver = request ~= nil and not Record.isHere(request, identity)
	if payload.release then
		meta.ActiveSession = nil
	end
	value.WasOverwritten = false
	return value, { kind = "saved", handOver = handOver, record = value, messages = Messages.list(value) }
end

--> The disown transform: frees the key if the load `identity` (its GUID) holds it, or with `loadCount`
--> if this server holds it at that load count; writes nothing otherwise.
function Lock.disown(value: any, identity: Record.Identity, now: number, loadCount: number?): any?
	if Record.classify(value) ~= "profile" then
		return nil
	end
	const meta = value.MetaData
	const active = meta.ActiveSession
	const named = if loadCount then meta.SessionLoadCount == loadCount else active and active[3] == identity.guid
	if not Record.isHere(active, identity) or not named then
		return nil
	end
	meta.ActiveSession = nil
	meta.LastUpdate = now
	Record.ours(meta).lease += 1
	return value
end

return Lock
