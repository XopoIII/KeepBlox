--!strict
--- DocumentService (downloaded, unmodified; its Roblox build, `target/roblox`) behind the simulator's
--- `Adapter` shape, used as its docs say: a session-locked `DocumentStore`, `GetDocument(key):Open()`,
--- and `Close()` on leave.
---
--- Its cache is deep-frozen, so the game keeps its own table and hands a copy to `SetCache` before
--- every write (`HookBefore("Update")`, which runs for autosaves and the close as well).
--- `GetUpdatedSignal` reports exactly what each write stored: those are the acknowledgements.
const Adapter = require("@sim/Adapter")
const Encoding = require("@fakes/Encoding")
const Rival = require("./Rival")

const TREE = Rival.tree("DocumentService")
const STORE = "Profiles"

--> `{documentServiceSchemaVersion, sessionLockId, lockTimestamp, isLocked, dataSchemaVersion,
--> lastCompatibleVersion, data}` (Document.luau).
const FORMAT: Adapter.Format = {
	data = function(value: any): Adapter.Data?
		return if type(value) == "table" and type(value.data) == "table" then value.data else nil
	end,
}

const DocumentServiceAdapter: Adapter.Adapter = {
	name = "DocumentService",
	store = `{STORE}/global`,
	format = FORMAT,
	boot = function(env: any): Adapter.Library
		const DocumentService = env.globals.require(env:mount(TREE))
		const DataStoreService = env.globals.game:GetService("DataStoreService")
		const store = DocumentService.DocumentStore.new({
			dataStore = DataStoreService:GetDataStore(STORE),
			check = function(value: unknown): (boolean, any)
				return type(value) == "table" and type((value :: any).p) == "table", value
			end,
			default = { p = {} },
			migrations = {},
			lockSessions = true,
		})
		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const document = store:GetDocument(key)
				const opened = document:Open()
				if not opened.success then
					return nil
				end
				const data = Encoding.copy(opened.data)
				if hooks.cancelled() then
					document:Close()
					return nil
				end
				document:HookBefore("Update", function()
					document:SetCache(Encoding.copy(data))
				end)
				document:GetUpdatedSignal():Connect(function(result: any)
					if result.success and type(result.data) == "table" then
						hooks.acked(Encoding.copy(result.data))
					end
				end)
				document:GetClosedSignal():Connect(function()
					hooks.ended()
				end)
				return {
					data = data,
					isActive = function(): boolean
						return document:IsOpen() and not document:IsClosing()
					end,
					release = function()
						document:Close()
					end,
				}
			end,
		}
	end,
}

return DocumentServiceAdapter
