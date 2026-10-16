--!strict
--- Shared documents: data no one server owns (a guild, a clan, a global counter), changed by any server
--- at any time without a session lock.
---
---     const guilds = KeepBlox.shared("Guilds", { template = { members = {}, bank = 0 } })
---     guilds:update(guildId, function(data) data.bank += 50 end)
---     guilds:watch(guildId, function(data) refreshGuildUi(data) end)
---
--- `update` runs `change` inside one UpdateAsync, on the value the store holds at that moment, so
--- concurrent updates from many servers never overwrite each other. That is also its contract:
--- `change` must not yield, and it may run more than once (the engine retries it when another server
--- wrote in between). Data is checked as a profile's is, before the write, with the path of a bad value.
--- A call is tried again when the data store fails, and a try that failed or timed out may still have
--- gone through, so each update carries one id for all its tries, stored with the change: the change
--- lands once (see Once). An update that answers "failed" may still land, once.
--- `watch` hears about every update made through a shared store, from any server (MessagingService,
--- best effort), and reads the document again.
---
--- Use a data store of its own: a key of a profile store is session-locked, and `update` refuses it.
---
--- In Studio, a place that cannot reach live data (never published, or API access off) keeps the
--- documents in memory and says so once through `onError`, as a profile store does (see Studio).
const Call = require("./Call")
const Config = require("./Config")
const Once = require("./Once")
const Record = require("./Record")
const Report = require("./Report")
const Schema = require("./Schema")
const Services = require("./Services")
const Signal = require("./Signal")
const Studio = require("./Studio")
const Validate = require("./Validate")

export type Options = {
	template: { [any]: any }?,
	schema: Schema.Node?,
	services: Services.Services?,
	config: Config.Overrides?,
	mock: (boolean | string)?,
}

export type Result =
	{ ok: true, data: any }
	| { ok: false, reason: "error" | "refused" | "foreign" | "locked" | "failed", message: string? }

export type SharedStore = {
	name: string,
	--> Fires `(key, message, kind)` for a problem worth logging. Today that is one: Studio cannot reach
	--> live data, so the documents are kept in memory (key "", kind "studio", once, on the first call).
	onError: Signal.Signal<string, string, Report.ErrorKind>,
	--> The document's data now (a copy); the template when it does not exist yet.
	read: (self: SharedStore, key: string) -> Result,
	--> Changes the document in one UpdateAsync (see the header). Returns the data stored.
	update: (self: SharedStore, key: string, change: (data: any) -> ()) -> Result,
	--> Calls `handler(data)` after each update of `key` made by any server.
	watch: (self: SharedStore, key: string, handler: (data: any) -> ()) -> Services.Connection,
}

const TOPIC_LIMIT = 80
--> Characters of a refusal's message kept with its id.
const BRIEF = 200

--> `text` cut to `BRIEF` characters, or nil when it is not valid UTF-8.
const function brief(text: string): string?
	const length = utf8.len(text)
	if length == nil then
		return nil
	end
	return if length <= BRIEF then text else string.sub(text, 1, (utf8.offset(text, BRIEF + 1) :: number) - 1)
end

--> The answer a stored refusal (`{reason, message}`, any shape) gives again.
const function refusalOf(fate: any): Result
	const reason = if type(fate) == "table" and fate[1] == "error" then "error" else "refused"
	const message = if type(fate) == "table" and type(fate[2]) == "string" then fate[2] else nil
	return { ok = false, reason = reason, message = message } :: Result
end

const Shared = {}

function Shared.new(name: string, options: Options): SharedStore
	assert(type(name) == "string" and #name > 0, "KeepBlox: a shared store needs a name")
	assert(
		(options.template == nil) ~= (options.schema == nil),
		"KeepBlox: a shared store needs a template or a schema"
	)
	const template = if options.schema then Schema.default(options.schema) else Record.copy(options.template)
	const config = Config.resolve(options.config)
	const origin = options.services or require("./RobloxServices").build()
	const clock = origin.clock
	const onError: Signal.Signal<string, string, Report.ErrorKind> = Signal.new(clock.spawn)
	-- `chosen` moves to memory when Studio cannot reach live data: its fields are read at each call.
	const chosen = Studio.choose(origin, name, if options.mock == true then "shared" else options.mock, "live")
	const prepare = Studio.guard(chosen, name, function(key: string, message: string, kind: Report.ErrorKind)
		onError:fire(key, message, kind)
	end)

	const function topic(key: string): string
		const text = `KB_{name}/{key}`
		assert(#text <= TOPIC_LIMIT, `KeepBlox: "{text}" is over the {TOPIC_LIMIT} characters a topic may have`)
		return text
	end

	const function dataOf(value: any): any
		const data = if Record.classify(value) == "profile" then Record.copy(value.Data) else Record.copy(template)
		return if options.schema then Schema.reconcile(options.schema, data) else data
	end

	-- A call retried with backoff until it answers or `loadTimeout` passes.
	const function retried(fn: () -> ...any): (boolean, ...any)
		const started = clock.now()
		local delay = config.backoffMin
		while true do
			const results = table.pack(Call.run(clock, config.callTimeout, fn))
			if results[1] or clock.now() - started > config.loadTimeout then
				return table.unpack(results, 1, results.n)
			end
			clock.wait(delay)
			delay = math.min(delay * 2, config.backoffMax)
		end
	end

	return {
		name = name,
		onError = onError,
		read = function(_: SharedStore, key: string): Result
			prepare()
			const ok, value = retried(function(): any
				return (chosen.dataStore:GetAsync(key, false))
			end)
			if not ok then
				return { ok = false, reason = "failed", message = tostring(value) }
			elseif Record.classify(value) == "foreign" then
				return { ok = false, reason = "foreign" }
			end
			return { ok = true, data = dataOf(value) }
		end,
		update = function(_: SharedStore, key: string, change: (data: any) -> ()): Result
			assert(type(change) == "function", "KeepBlox: update needs a function")
			prepare()
			-- One id for every try of this update, so a try that seemed to fail and its retry apply once
			-- (see Once).
			const id = origin.guid()
			const started, startedAt = clock.now(), clock.time()
			const lifetime = config.loadTimeout + config.callTimeout
			local tries = 0
			const ok, answer = retried(function(): any
				tries += 1
				const again = tries > 1
				local outcome: Result = { ok = false, reason = "failed" }
				const guarded, broken = Call.guard(function(value: any): any
					const kind = Record.classify(value)
					if kind == "foreign" then
						outcome = { ok = false, reason = "foreign" } :: Result
						return nil
					end
					const record = if kind == "profile" then value else Record.fresh(template, clock.time(), nil)
					if record.MetaData.ActiveSession ~= nil then
						outcome = {
							ok = false,
							reason = "locked",
							message = "a session holds this key: it is a profile",
						} :: Result
						return nil
					end
					const ours = Record.ours(record.MetaData)
					const keep = lifetime + Once.SKEW
					if Once.seen(ours.applied, id) then
						outcome = { ok = true, data = dataOf(record) } :: Result
						return nil
					end
					const told = Once.find(ours.refused, id)
					if told then
						outcome = refusalOf(told[3])
						return nil
					elseif clock.now() - started > lifetime then
						outcome = { ok = false, reason = "failed", message = "the update ran out of time" } :: Result
						return nil
					end
					-- A refusal by a retry is stored with its id: an earlier try may still be on its way, and
					-- must not land what the game was told did not (see Once).
					const function refuse(reason: "error" | "refused", message: string): any
						outcome = { ok = false, reason = reason, message = message } :: Result
						if not again then
							return nil
						end
						ours.refused =
							Once.note(ours.refused, id, startedAt, clock.time(), keep, { reason, brief(message) })
						return record
					end
					const data = dataOf(record)
					const changed, thrown = pcall(change, data)
					if not changed then
						return refuse("error", tostring(thrown))
					end
					local _, refusal = Validate.check(data, "Data")
					if refusal == nil and options.schema then
						refusal = Schema.check(options.schema, data)
					end
					if refusal then
						return refuse("refused", refusal)
					end
					record.Data = data
					record.MetaData.LastUpdate = clock.time()
					ours.applied = Once.note(ours.applied, id, startedAt, clock.time(), keep)
					outcome = { ok = true, data = Record.copy(data) } :: Result
					return record
				end)
				chosen.dataStore:UpdateAsync(key, guarded)
				const problem = broken()
				if problem then
					error(problem, 0)
				end
				return outcome
			end)
			if not ok then
				return { ok = false, reason = "failed", message = tostring(answer) }
			end
			const result: Result = answer
			if result.ok then
				clock.spawn(function()
					const messaging = chosen.services.messaging
					pcall(messaging.PublishAsync, messaging, topic(key), { at = clock.time() })
				end)
			end
			return result
		end,
		watch = function(self: SharedStore, key: string, handler: (data: any) -> ()): Services.Connection
			prepare()
			return chosen.services.messaging:SubscribeAsync(topic(key), function()
				const current = self:read(key)
				if current.ok then
					handler(current.data)
				end
			end)
		end,
	}
end

return Shared
