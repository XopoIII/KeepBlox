#!/usr/bin/env sh
# Runs the benchmarks on LuneBlox and fails when one is over its budget (bench/Run.luau).
#
# Usage: run-bench.sh   (no arguments)
set -e
export PATH="$HOME/.rokit/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

luneblox run bench/Run
