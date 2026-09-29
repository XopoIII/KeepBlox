--!strict
--- The engine services one virtual server offers Roblox code, over the fakes: DataStoreService,
--- MessagingService, HttpService, Players, ServerStorage, and RunService (from Engine).
---
--- Engine behaviour kept here:
--- - A number passed where the engine takes a string (a key) is converted, as the engine converts it.
--- - `GetRequestBudgetForRequestType` takes the legacy request types too: GetAsync is a read,
---   SetIncrementAsync a write, UpdateAsync both (it "consumes from both the read and write request
---   budgets", error-codes-and-limits), so its budget is the smaller one.
--- - `SetAsync` takes a `DataStoreSetOptions` as its fourth argument; its metadata is stored.
const Engine = require("./Engine")
const Instances = require("./Instances")
const Services = require("@keepblox/Services")
const World = require("@fakes/World")

const Env = {}

const LEGACY: { [string]: { Services.RequestType } } = {
	GetAsync = { "StandardRead" },
	GetVersionAsync = { "StandardRead" },
	SetIncrementAsync = { "StandardWrite" },
	UpdateAsync = { "StandardRead", "StandardWrite" },
	ListAsync = { "StandardList" },
	RemoveVersionAsync = { "StandardRemove" },
	StandardRead = { "StandardRead" },
	StandardWrite = { "StandardWrite" },
	StandardList = { "StandardList" },
	StandardRemove = { "StandardRemove" },
	GetSortedAsync = { "OrderedList" },
	SetIncrementSortedAsync = { "OrderedWrite" },
	OrderedRead = { "OrderedRead" },
	OrderedWrite = { "OrderedWrite" },
	OrderedList = { "OrderedList" },
	OrderedRemove = { "OrderedRemove" },
}

-- The metadata a DataStoreSetOptions carries, or nil.
const function metadataOf(options: any): any
	if type(options) ~= "table" or type(options.GetMetadata) ~= "function" then
		return nil
	end
	return (options :: any):GetMetadata()
end

--> Called after a write this server made committed, with what the store now holds.
export type WriteObserver = (store: string, key: string, value: any) -> ()

const function dataStoreService(server: World.Server, engine: Engine.Engine, observers: { WriteObserver }): any
	const services = server.services
	const function committed(store: string, key: string, value: any)
		for _, observer in observers do
			observer(store, key, value)
		end
	end
	const Enum = engine.Enum
	return {
		GetDataStore = function(_: any, name: string, scope: string?, _options: any): any
			const store = services.dataStores:GetDataStore(name, scope)
			const id = `{name}/{scope or "global"}`
			return {
				GetAsync = function(_: any, key: any, options: any): (any, any)
					return store:GetAsync(tostring(key), if options then options.UseCache else nil)
				end,
				SetAsync = function(_: any, key: any, value: any, userIds: { number }?, options: any): string
					const metadata = metadataOf(options)
					const version = store:SetAsync(tostring(key), value, userIds, metadata)
					committed(id, tostring(key), value)
					return version
				end,
				UpdateAsync = function(_: any, key: any, transform: any): (any, any)
					const value, info = store:UpdateAsync(tostring(key), transform)
					if info ~= nil then
						committed(id, tostring(key), value)
					end
					return value, info
				end,
				RemoveAsync = function(_: any, key: any): (any, any)
					return store:RemoveAsync(tostring(key))
				end,
				GetVersionAsync = function(_: any, key: any, version: string): (any, any)
					return store:GetVersionAsync(tostring(key), version)
				end,
				ListVersionsAsync = function(
					_: any,
					key: any,
					direction: any,
					minDate: number?,
					maxDate: number?,
					pageSize: number?
				): any
					const ascending = direction ~= Enum.SortDirection.Descending
					return store:ListVersionsAsync(tostring(key), ascending, minDate, maxDate, pageSize)
				end,
			}
		end,
		GetOrderedDataStore = function(_: any, name: string, scope: string?): any
			const store = services.dataStores:GetOrderedDataStore(name, scope)
			return {
				GetAsync = function(_: any, key: any): number?
					return store:GetAsync(tostring(key))
				end,
				SetAsync = function(_: any, key: any, value: number)
					store:SetAsync(tostring(key), value)
				end,
				UpdateAsync = function(_: any, key: any, transform: (number?) -> number?): number?
					return store:UpdateAsync(tostring(key), transform)
				end,
				RemoveAsync = function(_: any, key: any): number?
					return store:RemoveAsync(tostring(key))
				end,
				GetSortedAsync = function(
					_: any,
					ascending: boolean,
					pageSize: number,
					minValue: number?,
					maxValue: number?
				): any
					return store:GetSortedAsync(ascending, pageSize, minValue, maxValue)
				end,
			}
		end,
		GetRequestBudgetForRequestType = function(_: any, requestType: any): number
			const name = if type(requestType) == "table" then requestType.Name else requestType
			const pools = LEGACY[name] or error(`RobloxEnv: no budget for request type {name}`, 2)
			local smallest = math.huge
			for _, pool in pools do
				smallest = math.min(smallest, services.dataStores:GetRequestBudgetForRequestType(pool))
			end
			return smallest
		end,
	}
end

const function httpService(world: World.World): any
	const random = world.scheduler.random
	return {
		GenerateGUID = function(_: any, braces: boolean?): string
			const hex = function(digits: number): string
				local text = ""
				for _ = 1, digits do
					text ..= string.format("%X", random:integer(0, 15))
				end
				return text
			end
			const guid = `{hex(8)}-{hex(4)}-{hex(4)}-{hex(4)}-{hex(12)}`
			return if braces == false then guid else `\{{guid}\}`
		end,
	}
end

export type Players = {
	service: any,
	--> A player joins: an Instance under Players, with `UserId`.
	join: (userId: number) -> any,
	--> A player leaves: parented to nil, `AncestryChanged` and `PlayerRemoving` fire.
	leave: (player: any) -> (),
}

const function players(instances: Instances.Instances): Players
	const root = instances.mount({ name = "Players", children = {} })
	const added, removing = instances.signal(), instances.signal()
	const service = root
	rawset(service, "PlayerAdded", added)
	rawset(service, "PlayerRemoving", removing)
	rawset(service, "GetPlayers", function(_: any): { any }
		return root:GetChildren()
	end)
	return {
		service = service,
		join = function(userId: number): any
			const player = instances.mount({ name = `Player{userId}`, children = {} }, root)
			rawset(player, "ClassName", "Player")
			rawset(player, "UserId", userId)
			rawset(player, "AncestryChanged", instances.signal())
			rawset(player, "Kick", function() end)
			added:Fire(player)
			return player
		end,
		leave = function(player: any)
			removing:Fire(player)
			const children = root.__children
			const index = table.find(children, player)
			if index then
				table.remove(children, index)
			end
			player.Parent = nil
			player.AncestryChanged:Fire(player, nil)
		end,
	}
end

--> The services by name, for `game:GetService`.
function Env.build(
	world: World.World,
	server: World.Server,
	engine: Engine.Engine,
	instances: Instances.Instances,
	observers: { WriteObserver }
): ({ [string]: any }, Players)
	const services = server.services
	const playerList = players(instances)
	return {
		DataStoreService = dataStoreService(server, engine, observers),
		MessagingService = {
			PublishAsync = function(_: any, topic: string, message: any)
				services.messaging:PublishAsync(topic, message)
			end,
			SubscribeAsync = function(_: any, topic: string, callback: (any) -> ()): any
				return services.messaging:SubscribeAsync(topic, callback)
			end,
		},
		HttpService = httpService(world),
		RunService = engine.RunService,
		Players = playerList.service,
		MemoryStoreService = server.memoryStores,
		ServerStorage = instances.mount({ name = "ServerStorage", children = {} }),
	},
		playerList
end

return Env
