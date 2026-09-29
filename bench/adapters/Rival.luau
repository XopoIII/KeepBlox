--!strict
--- What every rival adapter shares: reading a downloaded library, and acknowledging saves for a library
--- that has no "saved, with this data" signal.
---
--- Such a library is acknowledged at the service boundary: after a write it made on this server
--- commits, while the key's session is live there, the data that write stored is acknowledged. That is
--- exactly what the store holds, so an acknowledgement is never claimed for data that was not stored.
const Adapter = require("@sim/Adapter")
const Encoding = require("@fakes/Encoding")
const RobloxEnv = require("@sim/RobloxEnv")
const fs = require("@lune/fs")

export type Live = { hooks: Adapter.Hooks, live: () -> boolean }

const Rival = {}

const ROOT = "bench/rivals"

--> The module tree of a downloaded rival, or an error that says how to get it.
function Rival.tree(name: string): RobloxEnv.Node
	const path = `{ROOT}/{name}`
	assert(fs.isDir(path), `{path} is missing: run \`luneblox run bench/download\` first`)
	return RobloxEnv.tree(path, name)
end

--> The pinned version of a downloaded rival, from bench/rivals/VERSIONS.
function Rival.version(name: string): string
	const text = fs.readFile(`{ROOT}/VERSIONS`)
	return string.match(text, `{name} = "([^"]+)"`) or "unknown"
end

--> Acknowledges every committed write to `store` this server makes for a live session in `sessions`.
function Rival.ackWrites(env: RobloxEnv.Env, store: string, format: Adapter.Format, sessions: { [string]: Live })
	env:onWrite(function(written: string, key: string, value: any)
		const session = sessions[key]
		if written ~= store or session == nil or not session.live() then
			return
		end
		const data = format.data(value)
		if data then
			session.hooks.acked(Encoding.copy(data))
		end
	end)
end

return Rival
