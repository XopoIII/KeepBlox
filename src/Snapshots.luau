--!strict
--- What one beat carries of a store's open profiles (see Lease): a snapshot of each whose data changed
--- since it was last stored.
---
--- A snapshot up to `snapshotBytes` holds the whole data (`d`). A larger profile's holds only the edits
--- from the data as last stored (`p`, see Delta), with that data's fingerprint (`b`): the whole of it would
--- not fit, since an experience's MemoryStore holds about 1 KB per player, while its edits between two
--- writes usually do. Whole snapshots stay in the entry's `s` and edits go in `x`, which a KeepBlox before
--- 0.5 does not read, so an older server taking over never mistakes edits for data.
const Codec = require("./Codec")
const Delta = require("./Delta")
const Migrate = require("./Migrate")
const Record = require("./Record")
const Repair = require("./Repair")
const Types = require("./Types")
const Validate = require("./Validate")

export type Snapshot = {
	c: number,
	q: number,
	v: number,
	d: any,
	b: string?,
	p: { Delta.Edit }?,
	rc: { string },
	m: { number },
}

--> One beat's snapshots: whole ones (`whole`) and edits (`edits`), by key; which sessions are covered, by
--> a snapshot or because the store already holds their data; and the bytes they take.
export type Taken = {
	whole: { [string]: Snapshot },
	edits: { [string]: Snapshot },
	covered: { [Types.Session]: boolean },
}

-- Profiles stored larger than this are not walked at every beat: they are written at `renewFallback`.
const WALK_LIMIT = 128 * 1024

const Snapshots = {}

--> Notes that the store now holds `data` (as stored: at the plan's `write` version, maybe packed), whose
--> encoding is `encoded`. A copy of it is kept to make snapshot edits against, when it is small enough.
function Snapshots.stored(context: Types.Context, session: Types.Session, encoded: Validate.Encoded, data: any)
	session.storedText = encoded.text
	session.storedSize = encoded.size
	session.base = if encoded.size <= WALK_LIMIT and data ~= nil
		then { text = encoded.text, data = Record.copy(Codec.unpack(context.services.codec, data)), print = nil }
		else nil
end

-- The data as last stored, with its fingerprint; nil when there is none to make edits against.
const function base(session: Types.Session): Types.Base?
	const known = session.base
	if known == nil or known.text ~= session.storedText then
		return nil
	end
	known.print = known.print or Delta.fingerprint(known.data)
	return known
end

-- The data as it would be stored now, with its encoding (nil when it cannot be stored), and the play as
-- the game has it: copies, taken at once, since the check lets frames pass.
const function storable(context: Types.Context, session: Types.Session, pause: () -> ()): (any, Validate.Encoded?, any)
	const play = Record.copy(session.profile.Data)
	-- Stored as the data store would store it, at the version this server writes (see Migrate), so a
	-- server of the release before can take it over too.
	local data: any = play
	if context.plan.write < context.plan.version then
		data = Migrate.store(context.plan, Record.copy(play))
	end
	if data == nil then
		return nil, nil, play
	end
	local encoded = Validate.check(data, "Data", nil, pause)
	if encoded == nil then
		-- Stored repaired, as a save would store it (see Repair).
		if #Repair.run(data, "Data") > 0 then
			encoded = Validate.check(data, "Data", nil, pause)
		end
	end
	return data, encoded, play
end

--> The snapshots of `sessions` for one beat. `final`: the last beat of a closing server, whose
--> releases did not land; it may take up to `share` bytes for one profile.
function Snapshots.take(
	context: Types.Context,
	sessions: { [string]: Types.Session },
	share: number,
	final: boolean?
): Taken
	const cap = if final then share else context.config.snapshotBytes
	const taken: Taken = { whole = {}, edits = {}, covered = {} }
	const pause = Validate.slicer(context.services.clock)
	local total = 0
	-- Listed first: a session may open while a frame passes.
	const listed: { { key: string, session: Types.Session } } = {}
	for key, session in sessions do
		table.insert(listed, { key = key, session = session })
	end
	for _, item in listed do
		const key, session = item.key, item.session
		pause()
		if
			not session.active
			or (session.releasing and not final)
			or session.trading
			or session.storedSize > WALK_LIMIT
		then
			continue
		end
		-- A beat is a snapshot too: a game whose play lives outside `Data` writes it in `onSaving`. A release
		-- already had its own, final one.
		if not session.releasing then
			session.profile.onSaving:fire(false, nil)
		end
		const data, encoded, play = storable(context, session, pause)
		if encoded == nil or Codec.hasBuffer(data) then
			continue
		elseif encoded.text == session.storedText then
			taken.covered[session] = true
			continue
		end
		local size, edits, from = encoded.size, nil :: { Delta.Edit }?, nil :: string?
		if size > cap then
			const against = base(session)
			if against == nil then
				continue
			end
			edits = Delta.diff(against.data, data)
			const packed = Validate.check(edits, "Data", cap)
			if packed == nil then
				continue
			end
			size, from = packed.size, against.print :: string
		end
		if total + size > share then
			continue
		end
		if encoded.text ~= session.snapText then
			session.snapSeq += 1
			session.snapText = encoded.text
		end
		const processed = session.inbox:processed()
		const consumed = {}
		for index in processed do
			table.insert(consumed, index)
		end
		session.good = {
			text = encoded.text,
			size = encoded.size,
			data = data,
			play = play,
			consumed = table.clone(processed),
			receipts = table.clone(session.receipts),
		}
		const snapshot: Snapshot = {
			c = session.loadCount,
			q = session.snapSeq,
			v = context.plan.write,
			d = if edits then nil else Record.copy(data),
			b = from,
			p = if edits then Record.copy(edits) else nil,
			rc = table.clone(session.receipts),
			m = consumed,
		}
		if edits then
			taken.edits[key] = snapshot
		else
			taken.whole[key] = snapshot
		end
		total += size
		taken.covered[session] = true
	end
	return taken
end

--> The data a snapshot carries, made on `stored` (the record's data as claimed); nil when it holds
--> edits made against other data than `stored`.
function Snapshots.data(snapshot: Snapshot, stored: any): any
	const edits = snapshot.p
	if edits == nil then
		return snapshot.d
	elseif type(edits) ~= "table" or snapshot.b ~= Delta.fingerprint(stored) then
		return nil
	end
	return Delta.apply(Record.copy(stored), edits)
end

return Snapshots
