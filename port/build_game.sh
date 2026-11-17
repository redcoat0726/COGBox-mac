#!/bin/sh
# Build one game's native program from your own copy - the macOS counterpart of upstream's
# `tools\build.ps1`. This is a *build* script, not a setup script: everything it needs (the two
# rexglue SDKs, cmake, the game copy under <Game>-Native/game/) you prepare yourself, exactly as
# upstream asks its builders to.
#
#   ./port/build_game.sh gears2      # -> port/build-patched-tu6/gow2
#   ./port/build_game.sh gears3      # -> port/build-gow3/gow3
#   ./port/build_game.sh judgment    # -> port/build-gowj/gowj
#
# Prerequisites, in the same shape as docs/building.md's list for Windows:
#   port/sdk/           the rexglue *release* SDK unpacked (prebuilt libs, Vulkan loader, headers)
#   port/sdk-patched-cg the SDK built from source with COGBox's patch   (port/build_sdk.sh)
#   <Game>-Native/game/ your own copy: extracted/, the title update, and the codegen input in
#                       game/tu6/patched or game/tu4/patched (install puts all three there)
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

JOBS=$(sysctl -n hw.ncpu)

# Two configure passes on purpose. generated/<version>/sources.cmake is written by the codegen target
# *during* the build, and the include path for it is decided at configure time - so on a tree that has
# never been built, pass 1 finds no sources.cmake, codegen creates it, and pass 2 picks it up. Without
# this the first build fails on "gow*_init.h not found".
configure() {
  cmake -S "$TREE" -B "$OUT" -DCMAKE_BUILD_TYPE=RelWithDebInfo $SDK_ARGS \
    -DGN_GAME_VERSION="$VER" -DGN_BUILD_TESTS=OFF \
    -DGN_HOST_VULKAN_HEADERS="$ROOT/port/third_party/vulkan-headers/include"
}

case "${1:-}" in
  gears2)
    TREE=Gears2-Native; OUT=port/build-patched-tu6; TARGET=gow2; VER=tu6
    ./port/build.sh --patched --tu6 --configure
    cmake --build "$OUT" --target "${TARGET}_codegen" -j "$JOBS"
    exec ./port/build.sh --patched --tu6 --full
    ;;
  gears3)   TREE=Gears3-Native; OUT=port/build-gow3; TARGET=gow3; VER=tu6 ;;
  judgment) TREE=GearsJ-Native; OUT=port/build-gowj; TARGET=gowj; VER=base ;;
  *)
    echo "usage: build_game.sh gears2|gears3|judgment" >&2
    exit 2
    ;;
esac

[ -f "$ROOT/port/sdk/lib/librexruntime.dylib" ] || {
  echo "build_game.sh: port/sdk is missing - unpack rexglue-sdk-<ver>-mac-arm64.zip there first" >&2
  exit 1
}
[ -f "$ROOT/port/sdk-patched-cg/out/mac-arm64/librexruntimerd.dylib" ] || {
  echo "build_game.sh: port/sdk-patched-cg is missing - run port/build_sdk.sh first" >&2
  exit 1
}
[ -f "$ROOT/$TREE/game/extracted/default.xex" ] || {
  echo "build_game.sh: $TREE/game/extracted/default.xex is missing - add your own copy first" >&2
  exit 1
}

SDK_ARGS="-DREXSDK_DIR=$ROOT/port/sdk-patched-cg
-DREXGLUE_PORT_PREFIX=$ROOT/port/sdk
-DREXGLUE_PORT_PREBUILT=ON
-DREXGLUE_USE_VULKAN=ON
-DREXGLUE_BUILD_TESTS=OFF
-DREXGLUE_ENABLE_TRACY=OFF
-DCMAKE_CXX_FLAGS=-DGN_SDK_COGBOX_PATCH=1"

# shellcheck disable=SC2086
configure
cmake --build "$OUT" --target "${TARGET}_codegen" -j "$JOBS"
configure
cmake --build "$OUT" --target "$TARGET" -j "$JOBS"

[ -x "$OUT/$TARGET" ] || { echo "build_game.sh: $OUT/$TARGET was not produced" >&2; exit 1; }
echo "built: $OUT/$TARGET"
