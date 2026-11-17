#!/bin/sh
# Build cogbox-mac natively for this Mac (arm64 or x86_64). No dependencies beyond the Xcode command line tools:
# the filesystem core is upstream's own Gears2-Native/cogbox/src/x360fs.cpp (plain C++17, compiled here as is, so
# upstream's fixes arrive with a merge instead of drifting in a copy), Metal is reached through the system frameworks.
# Usage: ./build.sh [debug]
set -eu
cd "$(dirname "$0")"

CXX=${CXX:-clang++}
OPT=${OPT:--O2}
[ "${1:-}" = debug ] && { OPT="-O0 -g"; }

mkdir -p build
# shellcheck disable=SC2086
$CXX -std=c++20 $OPT -Wall -Wextra -Wno-unused-parameter \
  -DCOGBOX_SOURCE_DIR="\"$(pwd)\"" \
  -Isrc -IGears2-Native/cogbox/src \
  src/main.cpp src/mac_probe.mm Gears2-Native/cogbox/src/x360fs.cpp \
  -framework Metal -framework Foundation \
  -o build/cogbox-mac

echo "built: $(pwd)/build/cogbox-mac"
