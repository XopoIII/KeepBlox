--!strict
--- The real `Services` bundle, over the engine's services.
---
--- Nothing here runs at require time: `game` is touched only inside `build()`, so the module can be
--- required (and type-checked) anywhere. The adapter translates the seam's plain arguments into the
--- engine's option Instances and passes everything else straight through.
const Services = require("./Services")

const RobloxServices = {}

const function wrapStore(store: DataStore): Services.DataStore
	const wrapped = {}

	function wrapped.GetAsync(_: Services.DataStore, key: string, useCache: boolean?): (any, Services.KeyInfo?)
		const options = Instance.new("DataStoreGetOptions")
		options.UseCache = useCache ~= false
		local value, info = store:GetAsync(key, options)
		return value, info :: any
	end

	function wrapped.SetAsync(
		_: Services.DataStore,
		key: string,
		value: any,
		userIds: { number }?,
		metadata: { [string]: any }?
	): string
		local options: DataStoreSetOptions? = nil
		if metadata then
			local built = Instance.new("DataStoreSetOptions")
			built:SetMetadata(metadata)
			options = built
		end
		return store:SetAsync(key, value, userIds or {}, options)
	end

	function wrapped.UpdateAsync(
		_: Services.DataStore,
		key: string,
		transform: Services.Transform
	): (any, Services.KeyInfo?)
		-- The engine's DataStoreKeyInfo already has the seam's shape; only the Luau type differs.
		local value, info = store:UpdateAsync(key, transform :: any)
		return value, info :: any
	end

	function wrapped.RemoveAsync(_: Services.DataStore, key: string): (any, Services.KeyInfo?)
		local value, info = store:RemoveAsync(key)
		return value, info :: any
	end

	function wrapped.ListVersionsAsync(
		_: Services.DataStore,
		key: string,
		ascending: boolean?,
		minDate: number?,
		maxDate: number?,
		pageSize: number?
	): Services.VersionPages
		local direction = if ascending == false then Enum.SortDirection.Descending else Enum.SortDirection.Ascending
		local pages = store:ListVersionsAsync(key, direction, minDate or 0, maxDate or 0, pageSize or 0)
		return pages :: any
	end

	function wrapped.GetVersionAsync(_: Services.DataStore, key: string, version: string): (any, Services.KeyInfo?)
		local value, info = store:GetVersionAsync(key, version)
		return value, info :: any
	end

	return wrapped :: Services.DataStore
end

--> The bundle for this server. Call it once, from a server script, when the library starts.
function RobloxServices.build(): Services.Services
	const dataStoreService = game:GetService("DataStoreService")
	const messagingService = game:GetService("MessagingService")

	const dataStores = {}
	function dataStores.GetDataStore(_: Services.DataStoreService, name: string, scope: string?): Services.DataStore
		return wrapStore(dataStoreService:GetDataStore(name, scope))
	end
	function dataStores.GetRequestBudgetForRequestType(
		_: Services.DataStoreService,
		requestType: Services.RequestType
	): number
		return dataStoreService:GetRequestBudgetForRequestType((Enum.DataStoreRequestType :: any)[requestType])
	end

	const messaging = {}
	function messaging.PublishAsync(_: Services.Messaging, topic: string, message: any)
		messagingService:PublishAsync(topic, message)
	end
	function messaging.SubscribeAsync(
		_: Services.Messaging,
		topic: string,
		callback: (Services.Message) -> ()
	): Services.Connection
		return messagingService:SubscribeAsync(topic, callback) :: any
	end

	local clock: Services.Clock = {
		now = os.clock,
		time = function(): number
			return os.time()
		end,
		wait = function(dt: number?): number
			return task.wait(dt)
		end,
		spawn = function(fn: (...any) -> (), ...: any)
			task.spawn(fn, ...)
		end,
	}

	return {
		dataStores = dataStores :: Services.DataStoreService,
		messaging = messaging :: Services.Messaging,
		clock = clock,
		placeId = game.PlaceId,
		jobId = game.JobId,
	}
end

return RobloxServices
