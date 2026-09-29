#!/usr/bin/env sh
# The type gate: `luau-lsp analyze` over every Luau file we own, in strict mode (.luaurc).
#
# `src/` is analysed against the Roblox API definitions, since it runs in Roblox. `tests/` and
# `bench/` run on LuneBlox and see both: the `@lune` typedefs through the .luaurc alias, and the
# Roblox definitions for the types the library itself names.
#
# The Roblox definitions are downloaded once and kept out of git; `luneblox setup` writes the
# `@lune` typedefs that .luaurc aliases, so CI has them too.
#
# Usage: type-check.sh   (no arguments)
set -e
export PATH="$HOME/.rokit/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for arg in "$@"; do
	echo "type-check: unknown argument '$arg' (it takes none; the whole tree is checked)" >&2
	exit 2
done

if [ ! -f globalTypes.d.luau ]; then
	curl -fsSL -o globalTypes.d.luau \
		"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
fi
luneblox setup >/dev/null

# The new type solver, as Roblox Studio runs it: without it, luau-lsp rejects `read` and `write`
# property modifiers and checks against rules no game is checked with any more.
luau-lsp analyze --flag:LuauSolverV2=true --defs globalTypes.d.luau --ignore "tests/reference/**" --ignore "bench/rivals/**" src tests bench
echo "type-check: clean"
