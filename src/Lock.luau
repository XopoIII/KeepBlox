--!strict
--- The lock, as pure `UpdateAsync` transforms: every decision is made from the stored record alone,
--- inside the transform, so it holds however calls interleave and whatever the local clock says.
---
--- - `claim` takes a free key, or one this server already holds. It asks the owner of a held key to
---   hand it over by writing `ForceLoadSession`. With `steal`, it takes the key only if that request
---   is still ours (a third server asking since then wins, as in ProfileStore).
--- - `force` takes the key from whoever holds it, at once (ProfileStore's `Steal = true`).
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
	force: boolean?
): (any?, Claim)
	const kind = Record.classify(value)
	if kind == "foreign" then
		return nil, { kind = "foreign", value = value }
	end
	const record = if kind == "profile" then value else Record.fresh(template, now, value and value.GlobalUpdates)
	const meta = record.MetaData
	const active = meta.ActiveSession
	if active == nil or Record.isHere(active, identity) then
		const claim = take(record, identity, now)
		return record, claim
	end

	const ours = Record.ours(meta)
	const request = meta.ForceLoadSession
	if force then
		return record, take(record, identity, now)
	end
	if steal then
		if Record.isHere(request, identity) then
			const claim = take(record, identity, now)
			return record, claim
		end
		return nil, { kind = "outbid" }
	end
	meta.ForceLoadSession = { identity.placeId, identity.jobId }
	return record,
		{
			kind = "busy",
			owner = {
				session = active,
				lease = if ours.owner ~= nil and ours.owner == active[3] then ours.lease else nil,
				lastUpdate = meta.LastUpdate,
				loadCount = meta.SessionLoadCount or 0,
			},
		}
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
