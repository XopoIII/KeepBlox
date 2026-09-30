--!strict
--- Run on the play server (Studio MCP `execute_luau` with the Server data model, or the server's
--- command bar) after `Load.luau` built the folder. Set `WHICH` to "functional" or "stress". Read the
--- progress from `ServerStorage.KB_LiveCheck.Log.Value`; the last line starts with "DONE".
const WHICH = "functional"

const ServerStorage = game:GetService("ServerStorage")
const root = ServerStorage:WaitForChild("KB_LiveCheck")
const Run = (require :: any)(root:WaitForChild("Live"):WaitForChild("Run"))
const keepBlox = root:WaitForChild("KeepBlox")
print(Run.start({
	KeepBlox = (require :: any)(keepBlox),
	RobloxServices = (require :: any)(keepBlox:WaitForChild("RobloxServices")),
	ProfileStore = (require :: any)(root:WaitForChild("ProfileStore")),
}, root:WaitForChild("Log"), WHICH))
