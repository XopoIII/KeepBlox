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
--- `watch` hears about every update made through a shared store, from any server (MessagingService,
--- best effort), and reads the document again.
---
--- Use a data store of its own: a key of a profile store is session-locked, and `update` refuses it.
const Call = require("./Call")
const Config = require("./Config")
const MockServices = require("./MockServices")
const Record = require("./Record")
const Schema = require("./Schema")
const Services = require("./Services")
const Validate = require("./Validate")

export type Options = {
	template: { [any]: any }?,
	schema: Schema.Node?,
	services: Services.Services?,
	config: { [string]: number }?,
	mock: (boolean | string)?,
}

export type Result =
	{ ok: true, data: any }
	| { ok: false, reason: "error" | "refused" | "foreign" | "locked" | "failed", message: string? }

export type SharedStore = {
	read name: string,
	--> The document's data now (a copy); the template when it does not exist yet.
	read: (self: SharedStore, key: string) -> Result,
	--> Changes the document in one UpdateAsync (see the header). Returns the data stored.
	update: (self: SharedStore, key: string, change: (data: any) -> ()) -> Result,
	--> Calls `handler(data)` after each update of `key` made by any server.
	watch: (self: SharedStore, key: string, handler: (data: any) -> ()) -> Services.Connection,
}

const TOPIC_LIMIT = 80

const Shared = {}

function Shared.new(name: string, options: Options): SharedStore
	assert(type(name) == "string" and #name > 0, "KeepBlox: a shared store needs a name")
	assert(
		(options.template == nil) ~= (options.schema == nil),
		"KeepBlox: a shared store needs a template or a schema"
	)
	const template = if options.schema then Schema.default(options.schema) else Record.copy(options.template)
	const config = Config.resolve(options.config)
	local services = options.services or require("./RobloxServices").build()
	if options.mock then
		services = MockServices.wrap(services, if type(options.mock) == "string" then options.mock else "shared")
	end
	const clock = services.clock
	const dataStore = services.dataStores:GetDataStore(name)

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
		read = function(_: SharedStore, key: string): Result
			const ok, value = retried(function(): any
				return (dataStore:GetAsync(key, false))
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
			local outcome: Result = { ok = false, reason = "failed" }
			const ok, problem = retried(function(): any
				return dataStore:UpdateAsync(key, function(value: any): any
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
					const data = dataOf(record)
					const changed, thrown = pcall(change, data)
					if not changed then
						outcome = { ok = false, reason = "error", message = tostring(thrown) } :: Result
						return nil
					end
					local _, refusal = Validate.check(data, "Data")
					if refusal == nil and options.schema then
						refusal = Schema.check(options.schema, data)
					end
					if refusal then
						outcome = { ok = false, reason = "refused", message = refusal } :: Result
						return nil
					end
					record.Data = data
					record.MetaData.LastUpdate = clock.time()
					outcome = { ok = true, data = Record.copy(data) } :: Result
					return record
				end)
			end)
			if not ok then
				return { ok = false, reason = "failed", message = tostring(problem) }
			end
			if outcome.ok then
				clock.spawn(function()
					pcall(services.messaging.PublishAsync, services.messaging, topic(key), { at = clock.time() })
				end)
			end
			return outcome
		end,
		watch = function(self: SharedStore, key: string, handler: (data: any) -> ()): Services.Connection
			return services.messaging:SubscribeAsync(topic(key), function()
				const current = self:read(key)
				if current.ok then
					handler(current.data)
				end
			end)
		end,
	}
end

return Shared
