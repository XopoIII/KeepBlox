--!strict
--- Serves the live check to Roblox Studio: `luneblox run tests/live/Serve` (see tests/live/README.md).
---
--- `http://127.0.0.1:34871/bundle.json` is `{ src = { [path] = text }, live = { [name] = text },
--- ProfileStore = text }`, read from disk on every request, so an edit is picked up by the next load
--- in Studio. Only the loopback address is served.
const fs = require("@lune/fs")
const net = require("@lune/net")
const serde = require("@lune/serde")

const PORT = 34871

-- Every .luau file under `root`, by its path relative to `root`.
const function tree(root: string, prefix: string, into: { [string]: string }): { [string]: string }
	for _, name in fs.readDir(root) do
		const path = `{root}/{name}`
		if fs.isDir(path) then
			tree(path, `{prefix}{name}/`, into)
		elseif string.sub(name, -5) == ".luau" then
			into[`{prefix}{name}`] = fs.readFile(path)
		end
	end
	return into
end

const function bundle(): string
	const live: { [string]: string } = {}
	for path, text in tree("tests/live", "", {}) do
		if path ~= "Serve.luau" and path ~= "Load.luau" and path ~= "Start.luau" then
			live[string.sub(path, 1, -6)] = text
		end
	end
	return serde.encode("json", {
		src = tree("src", "", {}),
		live = live,
		ProfileStore = fs.readFile("tests/reference/ProfileStore.luau"),
	})
end

net.serve(PORT, {
	address = "http://127.0.0.1",
	handleRequest = function(request: net.ServeRequest): net.ServeResponse
		if request.path ~= "/bundle.json" then
			return { status = 404, body = "not found" }
		end
		return { status = 200, headers = { ["Content-Type"] = "application/json" }, body = bundle() }
	end,
})
print(`Serving the live check on http://127.0.0.1:{PORT}/bundle.json (Ctrl+C to stop)`)
