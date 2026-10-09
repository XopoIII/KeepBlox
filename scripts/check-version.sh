#!/usr/bin/env sh
# One version, in every place a release names it.
#
# WHY IT IS ENFORCED RATHER THAN AGREED: a release carries its version in seven places (wally.toml,
# pesde.toml, pesde.lock, README.md twice, two pages of the docs, CHANGELOG.md), and they were kept
# in step by hand. A drift is invisible to every other gate: the packages build and the tests pass
# with the README pointing at a version that is not the one being published.
#
# wally.toml is the source of truth; everything else must say what it says. Between releases the tree
# still passes: it names the version that is out, and the changelog holds its entry.
#
# Usage: check-version.sh   (no arguments)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' wally.toml)"
if [ -z "$version" ]; then
	echo "check-version: no version found in wally.toml" >&2
	exit 1
fi

# The version, escaped for grep's basic regexes (its dots must be literal).
escaped="$(printf '%s' "$version" | sed 's/\./\\./g')"

status=0
check() { # check <file> <pattern> <what>
	if ! grep -q "$2" "$1"; then
		echo "check-version: $1 does not name $3 \"$version\"" >&2
		status=1
	fi
}

check pesde.toml "^version = \"$escaped\"$" "the package version"
check pesde.lock "^version = \"$escaped\"$" "the locked version"
check README.md "Status: $escaped\." "the status line"
check README.md "xopoiii/keepblox@$escaped" "the Wally install line"
check docs/src/content/docs/index.mdx "KeepBlox $escaped " "the version"
check docs/src/content/docs/getting-started/installation.mdx "xopoiii/keepblox@$escaped" "the Wally install line"
check CHANGELOG.md "^## $escaped - " "its changelog entry"

if [ "$status" -ne 0 ]; then
	echo "" >&2
	echo "wally.toml says $version; every place a release names the version must agree." >&2
fi

exit "$status"
