#!/bin/sh
# Thin wrapper around the launcher, kept so `./port/run_gow3.sh` keeps working: `cogbox-mac play` owns the
# argument list, the KosmicKrisp ICD search and the data roots, and this script only forwards to it.
# Everything you pass goes straight through - `--dry-run --json`, `--lang zh-Hans`, `--set name=value`.
#
# The launch switches themselves live in src/main.cpp (native_launch), so there is one list, not two.
set -eu
cd "$(dirname "$0")/.."
[ -x build/cogbox-mac ] || { echo "run_gow3.sh: build/cogbox-mac is missing - run ./build.sh" >&2; exit 1; }
exec ./build/cogbox-mac play --game gears3 "$@"
