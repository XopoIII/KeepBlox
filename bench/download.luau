--!strict
--- Downloads the rival libraries the benchmarks run, each at an exact pin, into `bench/rivals/<name>`
--- (not part of the repository). ProfileStore is not here: it is vendored in tests/reference as the
--- fixed baseline.
---
---     luneblox run bench/download
---
--- Every pin is the latest stable release on the day it was set (2026-09-29), checked with
--- `gh release view`; a library with no releases is pinned to the head of its default branch. A patch
--- replaces exactly one occurrence of its text and fails loudly when that text is gone, so a patch that
--- stopped applying never produces numbers for a configuration nobody chose.
const fs = require("@lune/fs")
const net = require("@lune/net")
const process = require("@lune/process")

type Rival = {
	--> "owner/repo" on GitHub.
	repo: string,
	--> A tag or a commit.
	ref: string,
	--> What the report calls this version.
	version: string,
	--> The folders to keep from the archive, each as a module named by the key.
	modules: { [string]: string },
	patch: ((directory: string) -> ())?,
}

const ROOT = "bench/rivals"

--> Replaces the one occurrence of `find` in a downloaded file (see the header).
const function replace(path: string, find: string, with: string)
	const contents = fs.readFile(path)
	const first, last = string.find(contents, find, 1, true)
	assert(first and last, `{path} no longer contains {find}`)
	assert(string.find(contents, find, last + 1, true) == nil, `{path} contains {find} more than once`)
	fs.writeFile(path, string.sub(contents, 1, first - 1) .. with .. string.sub(contents, last + 1))
end

const RIVALS: { [string]: Rival } = {
	--> Stable and no longer supported; no releases, so the head of master (2024-10-13).
	ProfileService = {
		repo = "MadStudioRoblox/ProfileService",
		ref = "d736800444eda6bf75b18397f77dfb2c8f31f60f",
		version = "master d736800 (2024-10-13)",
		modules = { ProfileService = "ProfileService.lua" },
	},
	--> The last release (2021); the library is not maintained.
	DataStore2 = {
		repo = "Kampfkarren/Roblox",
		ref = "ds2-1.4.0",
		version = "1.4.0",
		modules = { DataStore2 = "DataStore2" },
	},
	Lapis = {
		repo = "nezuo/lapis",
		ref = "v0.3.3",
		version = "0.3.3",
		modules = { Lapis = "src" },
	},
	--> Lapis's dependency, at the version its wally.toml names.
	Promise = {
		repo = "evaera/roblox-lua-promise",
		ref = "v4.0.0",
		version = "4.0.0",
		modules = { Promise = "lib" },
	},
	--> 2.0.0 is a prerelease; 1.2.2 is the latest stable. `target/roblox` is what its package ships.
	DocumentService = {
		repo = "anthony0br/DocumentService",
		ref = "v1.2.2",
		version = "1.2.2",
		modules = { DocumentService = "target/roblox" },
	},
}

-- Copies a file or a folder, recursively.
const function copy(from: string, to: string)
	if fs.isDir(from) then
		fs.writeDir(to)
		for _, entry in fs.readDir(from) do
			copy(`{from}/{entry}`, `{to}/{entry}`)
		end
	else
		fs.writeFile(to, fs.readFile(from))
	end
end

const function download(name: string, rival: Rival)
	const archive = `{ROOT}/{name}.tar.gz`
	const response = net.request({ url = `https://codeload.github.com/{rival.repo}/tar.gz/{rival.ref}` })
	assert(response.ok, `{name}: HTTP {response.statusCode}`)
	fs.writeFile(archive, response.body)
	const unpacked = `{ROOT}/.{name}`
	if fs.isDir(unpacked) then
		fs.removeDir(unpacked)
	end
	fs.writeDir(unpacked)
	const result = process.exec("tar", { "xzf", archive, "-C", unpacked, "--strip-components=1" })
	assert(result.ok, `{name}: tar failed: {result.stderr}`)
	for module, source in rival.modules do
		const target = `{ROOT}/{module}`
		if fs.isDir(target) then
			fs.removeDir(target)
		elseif fs.isFile(target) then
			fs.removeFile(target)
		end
		const from = `{unpacked}/{source}`
		if fs.isFile(from) then
			-- A single-file module becomes a folder with its init, so every rival mounts the same way.
			fs.writeDir(target)
			fs.writeFile(`{target}/init.luau`, fs.readFile(from))
		else
			copy(from, target)
		end
		if rival.patch then
			rival.patch(target)
		end
	end
	fs.removeDir(unpacked)
	fs.removeFile(archive)
	print(`{name} {rival.version}`)
end

fs.writeDir(ROOT)
const only = process.args[1]
const lines = {}
for name, rival in RIVALS do
	if only == nil or only == name then
		download(name, rival)
		table.insert(lines, `{name} = "{rival.version}"`)
	end
end
table.sort(lines)
fs.writeFile(`{ROOT}/VERSIONS`, table.concat(lines, "\n") .. "\n")

-- `replace` is for rivals that need a patch; none does yet.
const _ = replace
