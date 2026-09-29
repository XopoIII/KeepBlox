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
---
--- A transform returns the record to write, or nil to write nothing, plus an outcome for the caller.
--- The engine may run it more than once; the last run's outcome is the one that counts.
const Messages = require("./Messages")
const Record = require("./Record")

export type Owner = {
	session: Record.Session,
	--> Our lease number, when the owner is a KeepBlox session; nil for a ProfileStore owner.
	lease: number?,
	lastUpdate: number?,
	loadCount: number,
}

export type Claim =
	{ kind: "taken", loadCount: number, record: any }
	| { kind: "busy", owner: Owner }
	| { kind: "outbid" }
	| { kind: "foreign", value: any }
	| { kind: "legacyLocked" }

--> How a claim treats a key someone else holds.
export type Mode = {
	--> Take the key from whoever holds it, at once (ProfileStore's `Steal = true`).
	force: boolean?,
	--> Never ask for a hand-over: a held key is left untouched, no `ForceLoadSession` is written.
	quiet: boolean?,
	--> With `quiet`: take a held key only while its owner is still this session at this lease, which
	--> the caller watched long enough to know it is dead.
	expect: Expected?,
	--> An importer's reader (see Import): a value that is not a profile is converted, not quarantined,
	--> when the reader recognises it. A value the old library still holds is left alone.
	adopt: ((value: any, info: any, now: number) -> { kind: string, data: any?, userIds: { number }? })?,
	--> The importer's name, recorded in a profile made from imported data.
	imported: string?,
	--> The template is data imported from elsewhere (not a new player's defaults).
	fromImport: boolean?,
	--> UserIds for a profile made from data imported from elsewhere.
	userIds: { number }?,
	--> The schema version a new profile's data is at: the template is written for the current schema,
	--> so no migration may run on it. Imported data gets none (it is from before every migration).
	version: number?,
}

export type Expected = { guid: string, loadCount: number, lease: number? }

export type Save =
	{ kind: "saved", handOver: boolean, record: any, messages: { Messages.Entry } }
	| { kind: "lost", owner: Record.Session? }

export type Payload = {
	--> The data to store, or nil to keep what is stored (a lease renewal).
	data: any?,
	userIds: { number }?,
	robloxMetaData: any?,
	--> Clears ActiveSession: the session ends with this write.
	release: boolean,
	--> Messages processed into `data`, removed from the queue by this same write.
	consumed: { [number]: boolean }?,
	--> Purchase receipt ids granted into `data`, stored by this same write.
	receipts: { string }?,
	--> The schema version `data` is at, stored with it.
	schemaVersion: number?,
}

const Lock = {}

const function take(record: any, identity: Record.Identity, now: number): Claim
	const meta = record.MetaData
	meta.ActiveSession = { identity.placeId, identity.jobId, identity.guid }
	meta.ForceLoadSession = nil
	meta.SessionLoadCount = (meta.SessionLoadCount or 0) + 1
	meta.LastUpdate = now
	const ours = Record.ours(meta)
	ours.owner = identity.guid
	ours.lease += 1
	record.WasOverwritten = false
	return { kind = "taken", loadCount = meta.SessionLoadCount, record = record }
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
	const kind = Record.classify(value)
	if kind == "foreign" then
		const adopt = mode and mode.adopt
		const found = if adopt then adopt(value, info, now) else nil
		if found and found.kind == "data" then
			const record = Record.fresh(found.data, now, nil)
			record.UserIds = table.clone(found.userIds or {})
			Record.ours(record.MetaData).importedFrom = (mode :: Mode).imported
			return record, take(record, identity, now)
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
	if active == nil or Record.isHere(active, identity) then
		const claim = take(record, identity, now)
		return record, claim
	end

	const ours = Record.ours(meta)
	const request = meta.ForceLoadSession
	const owner: Owner = {
		session = active,
		lease = if ours.owner ~= nil and ours.owner == active[3] then ours.lease else nil,
		lastUpdate = meta.LastUpdate,
		loadCount = meta.SessionLoadCount or 0,
	}
	if mode and mode.force then
		return record, take(record, identity, now)
	end
	if mode and mode.quiet then
		const expect = mode.expect
		if
			expect
			and expect.guid == tostring(active[3])
			and expect.loadCount == owner.loadCount
			and expect.lease == owner.lease
		then
			return record, take(record, identity, now)
		end
		return nil, { kind = "busy", owner = owner }
	end
	if steal then
		if Record.isHere(request, identity) then
			const claim = take(record, identity, now)
			return record, claim
		end
		return nil, { kind = "outbid" }
	end
	meta.ForceLoadSession = { identity.placeId, identity.jobId }
	return record, { kind = "busy", owner = owner }
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
	end
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

return Lock
