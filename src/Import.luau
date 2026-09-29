--!strict
--- Moving players' data from another library, one key at a time, on the key's first KeepBlox load.
---
---     KeepBlox.store("Profiles", {
---         template = TEMPLATE,
---         import = KeepBlox.importers.DocumentService({ store = "PlayerData" }),
---     })
---
--- When the KeepBlox key does not exist yet, the old library's value is read (read only; it is never
--- written, so switching back stays possible) and becomes the new profile's data. When the old value
--- lives at the same key of the same store, it is converted inside the claim's transform, so no server
--- of the old library can write in between.
---
--- It never guesses:
--- - a key the old library still holds (its lock is fresh) is waited on, like a KeepBlox lock, until
---   the load times out ("legacyLocked"): the old server is saving the player's last session;
--- - a failed read is retried, never taken for "no data" (a new player would start from the template
---   over data that exists);
--- - a value the importer does not recognise is left alone ("foreign").
---
--- Libraries that keep no lock in the value (DataStore2, Suphi's module) cannot say whether an old server
--- still plays the key: switch every server over first (shut the old ones down), then import.
const Call = require("./Call")
const Record = require("./Record")
const Services = require("./Services")
const Session = require("./Session")

--> What an importer found for a key.
export type Found =
	{ kind: "data", data: any, userIds: { number }? }
	--> The old library still holds the key: wait.
	| { kind: "locked" }
	--> Nothing: a new player.
	| { kind: "none" }
	--> A value this importer does not recognise.
	| { kind: "unknown" }

export type Importer = {
	--> Recorded in the new profile (`MetaData.KeepBlox.importedFrom`).
	name: string,
	--> Reads the old library's value for `key` from wherever it keeps it (it may yield and throw). Nil
	--> when the old value is at the same key of this store.
	fetch: ((services: Services.Services, key: string) -> (any, Services.KeyInfo?))?,
	--> Understands a value the old library stored. Pure and quick: it may run inside a transform.
	--> `now` is Unix seconds.
	read: (value: any, info: Services.KeyInfo?, now: number) -> Found,
}

--> What the claim should start a missing key from.
export type Prepared =
	{ ok: true, data: any?, userIds: { number }? }
	| { ok: false, reason: "legacyLocked" | "cancelled" | "closing" | "timeout" | "foreign" }

const Import = {}

-- One call, retried with backoff until it succeeds or the load must stop.
const function retrying(
	context: Session.Context,
	started: number,
	cancel: (() -> boolean)?,
	fn: () -> (any, any)
): (string?, any, any)
	const clock = context.services.clock
	local delay = context.config.backoffMin
	while true do
		if context.closing() then
			return "closing", nil, nil
		elseif cancel and cancel() then
			return "cancelled", nil, nil
		elseif clock.now() - started > context.config.loadTimeout then
			return "timeout", nil, nil
		end
		const ok, value, info = Call.run(clock, context.config.callTimeout, fn)
		if ok then
			return nil, value, info
		end
		context.report("", `import read failed: {value}`)
		clock.wait(delay)
		delay = math.min(delay * 2, context.config.backoffMax)
	end
end

--> Looks at `key` before the claim. A missing KeepBlox key with old data elsewhere gives that data;
--> anything else lets the claim go ahead as usual (it converts a same-key old value itself).
function Import.prepare(context: Session.Context, key: string, importer: Importer, cancel: (() -> boolean)?): Prepared
	const clock = context.services.clock
	const started = clock.now()
	local delay = context.config.backoffMin
	while true do
		const stopped, current = retrying(context, started, cancel, function(): (any, any)
			return context.dataStore:GetAsync(key, false)
		end)
		if stopped then
			return { ok = false, reason = stopped :: any }
		end
		const kind = Record.classify(current)
		if kind == "profile" then
			return { ok = true }
		end
		local found: Found = { kind = "none" }
		if kind == "foreign" then
			if importer.fetch ~= nil then
				return { ok = true } -- not the old library's key: the claim quarantines it
			end
			found = importer.read(current, nil, clock.time())
		elseif importer.fetch ~= nil then
			const fetch = importer.fetch
			const failed, old, info = retrying(context, started, cancel, function(): (any, any)
				return fetch(context.services, key)
			end)
			if failed then
				return { ok = false, reason = failed :: any }
			end
			found = if old == nil then { kind = "none" } :: Found else importer.read(old, info, clock.time())
		end
		if found.kind == "data" then
			return { ok = true, data = if importer.fetch then found.data else nil, userIds = found.userIds }
		elseif found.kind == "none" then
			return { ok = true }
		elseif found.kind == "unknown" then
			return if kind == "foreign" then { ok = true } else { ok = false, reason = "foreign" }
		end
		-- Locked: the old server is still saving; wait as for a KeepBlox owner.
		if context.closing() then
			return { ok = false, reason = "closing" }
		elseif cancel and cancel() then
			return { ok = false, reason = "cancelled" }
		elseif clock.now() - started + delay > context.config.loadTimeout then
			-- The next look would come after the deadline: the old lock is what kept the player out.
			return { ok = false, reason = "legacyLocked" }
		end
		clock.wait(delay)
		delay = math.min(delay * 2, context.config.backoffMax)
	end
end

return Import
