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
const Schema = require("./Schema")

export type Migration = (data: any) -> ...any

export type Plan = {
	schema: Schema.Node?,
	version: number,
	migrations: { [number]: Migration },
}

export type Outcome =
	{ ok: true, data: any, changed: boolean }
	| { ok: false, reason: "newerSchema" | "migration" | "schema", message: string }

const Migrate = {}

--> Checks a store's migration options, and returns its plan. Migrations must be numbered 1..version.
function Migrate.plan(schema: Schema.Node?, version: number?, migrations: { [number]: Migration }?): Plan
	const steps = migrations or {}
	local highest = 0
	for number, step in steps do
		assert(
			type(number) == "number" and number == math.floor(number) and number >= 1,
			"KeepBlox: migrations are numbered from 1"
		)
		assert(type(step) == "function", `KeepBlox: migration {number} is not a function`)
		highest = math.max(highest, number)
	end
	const current = version or highest
	assert(current >= highest, `KeepBlox: version {current} is below migration {highest}`)
	for number = 1, current do
		assert(steps[number] ~= nil, `KeepBlox: migration {number} is missing (they run 1..{current})`)
	end
	return { schema = schema, version = current, migrations = steps }
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
		const ok, result = pcall(plan.migrations[number], current)
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

return Migrate
