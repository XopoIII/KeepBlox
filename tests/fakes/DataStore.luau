--!strict
--- One server's `DataStore` handle over the shared fake backend: the seam's `Services.DataStore`.
---
--- Around each atomic backend operation it adds what a real call has
--- (https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore):
--- - latency: every call yields, so every call is a point where another server can act;
--- - the request budget and its queues (`Budget`), and injected faults (`Faults`);
--- - the local cache: "Keys are cached locally for 4 seconds after the first read ... Modifications to
---   the key by SetAsync() or UpdateAsync() apply to the cache immediately and restart the 4 second
---   timer." Cached reads cost no budget;
--- - UpdateAsync's retry: if another server wrote the key between the read and the write, "UpdateAsync()
---   will call the function again, discarding the result of the previous call". The transform "cannot
---   yield"; returning nil cancels. UserIds and metadata it does not return are cleared.
const Backend = require("./Backend")
const Budget = require("./Budget")
const Clock = require("./Clock")
const Encoding = require("./Encoding")
const Errors = require("./Errors")
const Faults = require("./Faults")
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")
const VersionPages = require("./VersionPages")

export type Context = {
	scheduler: Scheduler.Scheduler,
	backend: Backend.Backend,
	faults: Faults.Faults,
	budget: Budget.Budget,
	server: string,
	epoch: number?,
}

const CACHE_SECONDS = 4
const KEY_LIMIT = 50

type Cached = { value: any, info: Services.KeyInfo?, expires: number }

const DataStore = {}

function DataStore.new(context: Context, store: string): Services.DataStore
	const scheduler, backend, faults, budget = context.scheduler, context.backend, context.faults, context.budget
	const cache: { [string]: Cached } = {}

	const function nowMs(): number
		return Clock.trueMillis(scheduler, context.epoch)
	end

	const function checkKey(key: string)
		if key == "" then
			error(Errors.keyNameEmpty(), 0)
		elseif #key > KEY_LIMIT then
			error(Errors.keyNameLimit(), 0)
		end
	end

	-- A fault for this call and phase: throws, or parks the call for good.
	const function fault(op: string, key: string?, after: boolean)
		const rule = faults:match(op, key, context.server, after)
		if rule then
			if rule.hang then
				scheduler:wait(math.huge)
			end
			error(rule.error, 0)
		end
	end

	-- Half a round trip: the request travelling out, or the answer travelling back.
	const function travel()
		scheduler:wait(faults:sample() / 2)
	end

	const function remember(key: string, value: any, info: Services.KeyInfo?)
		cache[key] = { value = Encoding.copy(value), info = info, expires = scheduler.now + CACHE_SECONDS }
	end

	const function current(key: string): (any, Services.KeyInfo?)
		const latest = backend:latest(store, key)
		if latest == nil or latest.deleted then
			return nil, nil
		end
		return Encoding.copy(latest.value), VersionPages.keyInfo(latest, backend:createdMs(store, key) or 0)
	end

	const handle = {}

	function handle.GetAsync(_: Services.DataStore, key: string, useCache: boolean?): (any, Services.KeyInfo?)
		checkKey(key)
		const cached = cache[key]
		if useCache ~= false and cached and cached.expires > scheduler.now then
			return Encoding.copy(cached.value), cached.info
		end
		budget:acquire({ "StandardRead" }, "Get", Errors.queueFull(301, "GetAsync"))
		fault("GetAsync", key, false)
		travel()
		const value, info = current(key)
		travel()
		remember(key, value, info)
		return value, info
	end

	function handle.SetAsync(
		_: Services.DataStore,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	): string
		checkKey(key)
		if value == nil then
			error(Errors.unmodelled("SetAsync with a nil value"), 0)
		end
		Encoding.encode(value)
		budget:acquire({ "StandardWrite" }, "Set", Errors.queueFull(302, "SetAsync"))
		fault("SetAsync", key, false)
		travel()
		const version = backend:write(store, key, value, userIds or {}, metadata or {}, nowMs())
		fault("SetAsync", key, true)
		travel()
		remember(key, value, VersionPages.keyInfo(version, backend:createdMs(store, key) or 0))
		return version.id
	end

	function handle.UpdateAsync(
		_: Services.DataStore,
		key: string,
		transform: Services.Transform
	): (any, Services.KeyInfo?)
		checkKey(key)
		const queueFull = Errors.queueFull(304, "UpdateAsync")
		budget:acquire({ "StandardRead" }, "Update", queueFull)
		fault("UpdateAsync", key, false)
		local charged = false
		while true do
			travel()
			const base = backend:latest(store, key)
			const value, info = current(key)
			-- Run as a coroutine, so a transform that yields is caught rather than suspending the call.
			const thread = coroutine.create(transform)
			const ok, newValue, userIds, metadata = coroutine.resume(thread, value, info)
			if not ok then
				error(newValue, 0)
			elseif coroutine.status(thread) ~= "dead" then
				error("UpdateAsync transform yielded: the callback function cannot yield", 0)
			end
			if newValue == nil then
				travel()
				return nil, nil
			end
			Encoding.encode(newValue)
			if userIds ~= nil and type(userIds) ~= "table" then
				error(Errors.attributeFormat("userId"), 0)
			elseif metadata ~= nil and type(metadata) ~= "table" then
				error(Errors.attributeFormat("metadata"), 0)
			end
			if not charged then
				budget:acquire({ "StandardWrite" }, "Update", queueFull)
				charged = true
			end
			travel()
			-- Another server wrote in between: discard this result and run the transform again.
			if backend:latest(store, key) == base then
				const version = backend:write(store, key, newValue, userIds or {}, metadata or {}, nowMs())
				fault("UpdateAsync", key, true)
				const written = VersionPages.keyInfo(version, backend:createdMs(store, key) or 0)
				remember(key, newValue, written)
				return Encoding.copy(newValue), written
			end
		end
	end

	function handle.RemoveAsync(_: Services.DataStore, key: string): (any, Services.KeyInfo?)
		checkKey(key)
		budget:acquire({ "StandardRemove" }, "Remove", Errors.queueFull(306, "RemoveAsync"))
		fault("RemoveAsync", key, false)
		travel()
		const createdMs = backend:createdMs(store, key) or 0
		const previous = backend:remove(store, key, nowMs())
		fault("RemoveAsync", key, true)
		travel()
		remember(key, nil, nil)
		if previous == nil then
			return nil, nil
		end
		return Encoding.copy(previous.value), VersionPages.keyInfo(previous, createdMs)
	end

	const function listRequest(key: string)
		budget:acquire({ "StandardList" }, "List", "ListVersionsAsyncThrottle: request dropped, queue full.")
		fault("ListVersionsAsync", key, false)
		travel()
		travel()
	end

	function handle.ListVersionsAsync(
		_: Services.DataStore,
		key: string,
		ascending: boolean?,
		minDate: number?,
		maxDate: number?,
		pageSize: number?
	): Services.VersionPages
		checkKey(key)
		listRequest(key)
		return VersionPages.new(backend:versions(store, key), {
			ascending = ascending ~= false,
			minDate = minDate or 0,
			maxDate = maxDate or 0,
			pageSize = pageSize or 0,
		}, function()
			listRequest(key)
		end)
	end

	function handle.GetVersionAsync(_: Services.DataStore, key: string, id: string): (any, Services.KeyInfo?)
		checkKey(key)
		budget:acquire({ "StandardRead" }, "Get", "GetVersionAsyncThrottle: request dropped, queue full.")
		fault("GetVersionAsync", key, false)
		travel()
		const version = backend:version(store, key, id)
		travel()
		if version == nil or version.deleted then
			error(Errors.unmodelled("GetVersionAsync for a missing or deleted version"), 0)
		end
		return Encoding.copy(version.value), VersionPages.keyInfo(version, backend:createdMs(store, key) or 0)
	end

	return handle :: Services.DataStore
end

return DataStore
