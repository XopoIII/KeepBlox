--!strict
--- The stored record: ProfileStore's shape, so ProfileStore can read our keys and we can read its keys.
---
---     {
---       Data = {...},
---       MetaData = {
---         ProfileCreateTime, SessionLoadCount, LastUpdate,        -- os.time() seconds
---         ActiveSession = {PlaceId, JobId, GUID} | nil,
---         ForceLoadSession = {PlaceId, JobId} | nil,
---         MetaTags = {},
---         KeepBlox = { lease, owner },                            -- ours, and only ours
---       },
---       GlobalUpdates = {lastIndex, {{index, message}, ...}},
---       RobloxMetaData = {}, UserIds = {}, WasOverwritten = false,
---     }
---
--- Our state lives under `MetaData.KeepBlox` and nowhere else. `lease` goes up by one on every write
--- the owner makes, and `owner` is the GUID of the session that bumps it. A newcomer that sees the same
--- lease for long enough knows the owner is dead, without reading anyone's clock.

export type Session = { number | string } -- {PlaceId, JobId, GUID?}

export type Identity = {
	placeId: number,
	jobId: string,
	guid: string,
}

export type Kind = "profile" | "missing" | "messagesOnly" | "foreign"

const Record = {}

--> What a stored value is. Anything that is neither missing nor a ProfileStore-shaped record is
--> foreign: the library quarantines it instead of overwriting it.
function Record.classify(value: any): Kind
	if value == nil then
		return "missing"
	elseif type(value) ~= "table" then
		return "foreign"
	elseif type(value.Data) == "table" and type(value.MetaData) == "table" and type(value.GlobalUpdates) == "table" then
		return "profile"
	elseif value.Data == nil and value.MetaData == nil and type(value.GlobalUpdates) == "table" then
		return "messagesOnly"
	end
	return "foreign"
end

--> A deep copy; stored tables are never shared with the game's live data.
function Record.copy(value: any): any
	if type(value) ~= "table" then
		if typeof(value) == "buffer" then
			const result = buffer.create(buffer.len(value))
			buffer.copy(result, 0, value)
			return result
		end
		return value
	end
	-- A shallow clone in one engine call, then only the tables and buffers inside are copied in turn: far
	-- less work than setting every key (a profile is mostly scalars under a few tables).
	const result: { [any]: any } = table.clone(value)
	if getmetatable(result) ~= nil then
		setmetatable(result :: any, nil)
	end
	for key, item in result do
		const kind = type(item)
		if kind == "table" or kind == "buffer" then
			result[key] = Record.copy(item)
		end
	end
	return result
end

--> Fills string keys missing from `target` with copies from `template`, recursively into tables both
--> hold (ProfileStore's Reconcile). Existing values are never replaced, and array items are left alone.
function Record.reconcile(target: { [any]: any }, template: { [any]: any })
	for key, value in template do
		if type(key) == "string" then
			const current = target[key]
			if current == nil then
				target[key] = Record.copy(value)
			elseif type(current) == "table" and type(value) == "table" and not table.isfrozen(current) then
				Record.reconcile(current, value)
			end
		end
	end
end

--> A new record for a key that holds nothing (or only messages), not yet owned by anyone.
function Record.fresh(template: { [any]: any }, now: number, messages: any?): any
	return {
		Data = Record.copy(template),
		MetaData = {
			ProfileCreateTime = now,
			SessionLoadCount = 0,
			ActiveSession = nil,
			ForceLoadSession = nil,
			LastUpdate = now,
			MetaTags = {},
			KeepBlox = { lease = 0 },
		},
		GlobalUpdates = messages or { 0, {} },
		RobloxMetaData = {},
		UserIds = {},
		WasOverwritten = false,
	}
end

--> Whether a session tag names this server, as ProfileStore decides it: by PlaceId and JobId.
function Record.isHere(tag: any, identity: Identity): boolean
	return type(tag) == "table" and tag[1] == identity.placeId and tag[2] == identity.jobId
end

--> Our namespaced state in a record's MetaData, created if absent (a ProfileStore record has none).
function Record.ours(meta: any): {
	lease: number,
	owner: string?,
	receipts: { string }?,
	schemaVersion: number?,
	importedFrom: string?,
	--> An open trade (see Trade): its id and this profile's data from before it.
	trade: { id: string, before: any }?,
	--> The owner beats in MemoryStore (see Lease).
	memory: boolean?,
	--> The owner's latest MemoryStore snapshot number when this data was stored (see Lease).
	snap: number?,
	--> The last restore of this key (see Versions): the version it brought back, and when.
	restored: { from: string, at: number }?,
}
	local state = meta.KeepBlox
	if type(state) ~= "table" then
		state = { lease = 0 }
		meta.KeepBlox = state
	end
	if type(state.lease) ~= "number" then
		state.lease = 0
	end
	return state
end

--> The purchase receipt ids a record holds, oldest first (see Receipts).
function Record.receipts(meta: any): { string }
	const ours = if type(meta) == "table" then meta.KeepBlox else nil
	const list = if type(ours) == "table" then ours.receipts else nil
	return if type(list) == "table" then table.clone(list) else {}
end

return Record
