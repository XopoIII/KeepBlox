--!strict
--- Ordered, numbered migrations, run when a profile loads.
---
---     KeepBlox.store("Profiles", {
---         schema = schema,
---         version = 2,
---         migrations = {
---             [1] = function(data) data.coins = data.gold; data.gold = nil end,
---             [2] = function(data) return { stats = data } end,  -- may return a new table
---         },
---     })
---
--- A record stores the schema version its data is at (`MetaData.KeepBlox.schemaVersion`; records
--- without one, ProfileStore's included, are at 0). On load, every migration above it runs in order.
--- Then missing fields get their defaults, and the result is checked against the schema. A record
--- from a newer version than this server knows is refused, not guessed at: old code must never
--- rewrite data it does not understand. `KeepBlox.migrate` runs the same steps on a fixture, so
--- each migration can be tested with data from before and after it.
---
--- A release that can be rolled back (expand, then contract): a migration may be `{ up, down }`, and
--- `writeVersion` below `version` makes this server store its data at that older version, turned back
--- by the `down` steps. The server reads both, plays at `version`, and the release before it still
--- reads everything it writes, so rolling back loses no player. The next release raises
--- `writeVersion` once no server of the old one is left.
const Schema = require("./Schema")

export type Step = (data: any) -> ...any

--> One migration: the step up, or the step up and the step back down.
export type Migration = Step | { read up: Step, read down: Step }

export type Plan = {
	schema: Schema.Node?,
	--> The version this server plays at.
	version: number,
	--> The version this server stores data at (see the header).
	write: number,
	up: { [number]: Step },
	down: { [number]: Step },
}

export type Outcome =
	{ ok: true, data: any, changed: boolean }
	| { ok: false, reason: "newerSchema" | "migration" | "schema", message: string }

const Migrate = {}

--> Checks a store's migration options, and returns its plan. Migrations must be numbered 1..version,
--> and every one above `writeVersion` needs a `down`.
function Migrate.plan(
	schema: Schema.Node?,
	version: number?,
	migrations: { read [number]: Migration }?,
	writeVersion: number?
): Plan
	const up: { [number]: Step }, down: { [number]: Step } = {}, {}
	local highest = 0
	for number, migration in migrations or {} do
		assert(
			type(number) == "number" and number == math.floor(number) and number >= 1,
			"KeepBlox: migrations are numbered from 1"
		)
		if type(migration) == "table" then
			assert(type(migration.up) == "function", `KeepBlox: migration {number} has no up function`)
			assert(type(migration.down) == "function", `KeepBlox: migration {number} has no down function`)
			up[number], down[number] = migration.up, migration.down
		else
			assert(type(migration) == "function", `KeepBlox: migration {number} is not a function`)
			up[number] = migration
		end
		highest = math.max(highest, number)
	end
	const current = version or highest
	assert(current >= highest, `KeepBlox: version {current} is below migration {highest}`)
	for number = 1, current do
		assert(up[number] ~= nil, `KeepBlox: migration {number} is missing (they run 1..{current})`)
	end
	const write = if writeVersion == nil then current else writeVersion
	assert(
		write == math.floor(write) and write >= 0 and write <= current,
		`KeepBlox: writeVersion {write} must be a whole number from 0 to version {current}`
	)
	for number = write + 1, current do
		assert(down[number] ~= nil, `KeepBlox: migration {number} needs a down function (writeVersion is {write})`)
	end
	return { schema = schema, version = current, write = write, up = up, down = down }
end

--> The schema version a record's data is at: 0 when it has none (ProfileStore's records, for one).
function Migrate.stored(record: any): number
	const ours = type(record) == "table" and type(record.MetaData) == "table" and record.MetaData.KeepBlox
	return if type(ours) == "table" and type(ours.schemaVersion) == "number" then ours.schemaVersion else 0
end

--> Brings `data`, stored at version `from`, to the plan's version: the migrations, then the schema's
--> defaults, then its check. `data` may be changed in place.
function Migrate.run(plan: Plan, data: any, from: number): Outcome
	if from > plan.version then
		return {
			ok = false,
			reason = "newerSchema",
			message = `the data is at schema version {from}, newer than this server's {plan.version}`,
		}
	end
	local current = data
	for number = from + 1, plan.version do
		const ok, result = pcall(plan.up[number], current)
		if not ok then
			return { ok = false, reason = "migration", message = `migration {number} failed: {result}` }
		end
		if result ~= nil then
			current = result
		end
	end
	if plan.schema then
		current = Schema.reconcile(plan.schema, current)
		const problem = Schema.check(plan.schema, current)
		if problem then
			return { ok = false, reason = "schema", message = `the data does not fit the schema: {problem}` }
		end
	end
	return { ok = true, data = current, changed = from ~= plan.version }
end

--> `data`, at the plan's version, as it is stored: at `plan.write`, by the down steps. `data` must be a
--> copy the caller owns: it may be changed in place. Nil and the reason when a down step fails.
function Migrate.store(plan: Plan, data: any): (any, string?)
	local current = data
	for number = plan.version, plan.write + 1, -1 do
		const ok, result = pcall(plan.down[number], current)
		if not ok then
			return nil, `migration {number} failed going down: {result}`
		end
		if result ~= nil then
			current = result
		end
	end
	return current, nil
end

-- Whether two values are equal, deeply.
const function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b or (typeof(a) == "buffer" and typeof(b) == "buffer" and buffer.tostring(a) == buffer.tostring(b))
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

--> The template as a new profile is stored: at `plan.write`. When that is below the plan's version, the
--> template must come back unchanged through the down steps and up again, or the store is refused: a
--> `down` that does not undo its `up` would change every player's data on a rollback.
function Migrate.template(plan: Plan, template: any, copy: (any) -> any): any
	const stored, problem = Migrate.store(plan, copy(template))
	assert(problem == nil, `KeepBlox: the template cannot be stored at writeVersion: {problem}`)
	if plan.write < plan.version then
		const back = Migrate.run(plan, copy(stored), plan.write)
		assert(
			back.ok and same(back.data, template),
			`KeepBlox: the template does not come back through migrations {plan.write + 1}..{plan.version} down and up`
		)
	end
	return stored
end

--> Brings `data`, at the plan's version, down to `to` (a fixture's check of the down steps).
function Migrate.down(plan: Plan, data: any, to: number): (any, string?)
	assert(to == math.floor(to) and to >= 0 and to <= plan.version, `KeepBlox: {to} is outside 0..{plan.version}`)
	for number = to + 1, plan.version do
		assert(plan.down[number] ~= nil, `KeepBlox: migration {number} has no down function`)
	end
	const target = table.clone(plan)
	target.write = to
	return Migrate.store(target, data)
end

return Migrate
