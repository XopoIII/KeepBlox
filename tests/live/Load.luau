--!strict
--- Paste into Studio's command bar in Edit mode (or run it through Studio MCP), with
--- `luneblox run tests/live/Serve` running. It builds `ServerStorage.KB_LiveCheck` from the served
--- bundle: the library as `KeepBlox`, the vendored `ProfileStore`, the check under `Live`, and a
--- `Log` StringValue. Then start Play and run `Start.luau`'s lines on the server. Remove the folder
--- afterwards, before the place is saved or published.
assert(game.GameId == 10767242853, "the live check runs only in the test experience (roblox.env.example)")
const HttpService = game:GetService("HttpService")
const ServerStorage = game:GetService("ServerStorage")

const function module(name: string, source: string, parent: Instance): ModuleScript
	const script = Instance.new("ModuleScript")
	script.Name = name;
	(script :: any).Source = source
	script.Parent = parent
	return script
end

const existing = ServerStorage:FindFirstChild("KB_LiveCheck")
if existing then
	existing:Destroy()
end
const bundle = HttpService:JSONDecode(HttpService:GetAsync("http://127.0.0.1:34871/bundle.json"))
const root = Instance.new("Folder")
root.Name = "KB_LiveCheck"
const keepBlox = module("KeepBlox", bundle.src["init.luau"], root)
const folders: { [string]: Instance } = { [""] = keepBlox }
for path, source in bundle.src do
	if path ~= "init.luau" then
		const dir, file = string.match(path, "^(.-)/?([^/]+)%.luau$")
		local parent = folders[dir :: string]
		if parent == nil then
			parent = Instance.new("Folder")
			parent.Name = dir :: string
			parent.Parent = keepBlox
			folders[dir :: string] = parent
		end
		module(file :: string, source, parent)
	end
end
module("ProfileStore", bundle.ProfileStore, root)
const live = Instance.new("Folder")
live.Name = "Live"
live.Parent = root
for name, source in bundle.live do
	module(name, source, live)
end
const log = Instance.new("StringValue")
log.Name = "Log"
log.Parent = root
root.Parent = ServerStorage
print(`KB_LiveCheck built: {#root:GetDescendants()} instances`)
