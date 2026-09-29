--!strict
--- An in-memory MemoryStoreService for mock and Studio stores (see MockServices): sorted maps of
--- values that expire on the server's clock. Nothing here reaches a live memory store.
const Record = require("./Record")
const Services = require("./Services")

const MockMemory = {}

function MockMemory.new(clock: Services.Clock): Services.MemoryStores
	const maps: { [string]: { [string]: { value: any, expiresAt: number } } } = {}
	return {
		GetSortedMap = function(_: Services.MemoryStores, name: string): Services.MemoryMap
			maps[name] = maps[name] or {}
			const items = maps[name]
			const function live(key: string): any
				const item = items[key]
				return if item and item.expiresAt > clock.now() then Record.copy(item.value) else nil
			end
			return {
				GetAsync = function(_: Services.MemoryMap, key: string): any
					return live(key)
				end,
				UpdateAsync = function(
					_: Services.MemoryMap,
					key: string,
					transform: (value: any) -> any,
					expiration: number
				): any
					const value = transform(live(key))
					if value ~= nil then
						items[key] = { value = Record.copy(value), expiresAt = clock.now() + expiration }
					end
					return value
				end,
				RemoveAsync = function(_: Services.MemoryMap, key: string)
					items[key] = nil
				end,
			}
		end,
	}
end

return MockMemory
