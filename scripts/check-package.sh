#!/usr/bin/env sh
# Both packages carry every file of the library: each tracked file under src/ is in the pesde archive
# and in Wally's file list.
#
# WHY IT IS CHECKED: pesde reads `includes` as globs, so `"src"` matched the folder and nothing in
# it. The 0.1.0-0.3.0 pesde packages held only `src/init.luau`, whose first `require("@self/Config")`
# fails in any game that installs them, while every test here passed against the source tree. Only a
# look at the built package finds that.
#
# Usage: check-package.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git ls-files src | sort >"$WORK/expected"
if [ ! -s "$WORK/expected" ]; then
	echo "check-package: no tracked files under src/" >&2
	exit 1
fi

# pesde writes package.tar.gz next to the manifest, so it packs a copy of the tracked files (with
# rokit.toml, which rokit reads to find the pinned pesde).
mkdir "$WORK/pesde"
git ls-files src pesde.toml pesde.lock rokit.toml README.md LICENSE | while read -r file; do
	mkdir -p "$WORK/pesde/$(dirname "$file")"
	cp "$file" "$WORK/pesde/$file"
done
(cd "$WORK/pesde" && pesde publish --dry-run --yes >"$WORK/pesde.log" 2>&1) || {
	cat "$WORK/pesde.log" >&2
	echo "check-package: pesde publish --dry-run failed" >&2
	exit 1
}
tar -tzf "$WORK/pesde/package.tar.gz" | grep '^src/.*\.luau$' | sort >"$WORK/pesde.list"

wally package --list --output "$WORK/wally.tar" | sed 's|^\./||' | grep '^src/.*\.luau$' | sort >"$WORK/wally.list"

status=0
for manager in pesde wally; do
	missing="$(comm -23 "$WORK/expected" "$WORK/$manager.list")"
	if [ -n "$missing" ]; then
		echo "check-package: the $manager package leaves out:" >&2
		echo "$missing" | sed 's/^/  /' >&2
		status=1
	fi
done

if [ "$status" -eq 0 ]; then
	echo "check-package: pesde and Wally each carry all $(wc -l <"$WORK/expected" | tr -d ' ') files of src/"
fi
exit "$status"
