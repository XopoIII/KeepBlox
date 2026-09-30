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
luau-lsp analyze --flag:LuauSolverV2=true --defs globalTypes.d.luau --ignore "tests/reference/**" --ignore "bench/rivals/**" --ignore "tests/consumer/Misuse.luau" src tests bench

# A game may still be checked with the old solver, which drops every property written with `read` or
# `write`: the public types must read the same to it. tests/consumer/Game.luau uses the whole public API
# and must be clean there too; the library's own files are the new solver's business, so they are
# ignored in this run.
luau-lsp analyze --defs globalTypes.d.luau --ignore "src/**" tests/consumer/Game.luau

# tests/consumer/Misuse.luau must fail on exactly the lines marked `-- error`, under each solver: the
# consumer checks read real types, not `any`.
expected="$(grep -n -- '-- error$' tests/consumer/Misuse.luau | cut -d: -f1 | tr '\n' ' ')"
for solver in old new; do
	if [ "$solver" = new ]; then
		flag="--flag:LuauSolverV2=true"
	else
		flag="--flag:LuauSolverV2=false"
	fi
	got="$(luau-lsp analyze "$flag" --defs globalTypes.d.luau --ignore "src/**" tests/consumer/Misuse.luau 2>&1 |
		sed -n 's/^tests\/consumer\/Misuse\.luau(\([0-9]*\),.*/\1/p' | sort -n | tr '\n' ' ')" || true
	if [ "$got" != "$expected" ]; then
		echo "type-check: Misuse.luau under the $solver solver failed on lines [$got], expected [$expected]" >&2
		exit 1
	fi
done
echo "type-check: clean"
