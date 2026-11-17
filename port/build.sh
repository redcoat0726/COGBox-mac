#!/bin/sh
# Configure and build the Gears ports for macOS.
#
#   ./build.sh                 # layer 0 against the *released* SDK
#   ./build.sh --patched       # layer 0 against the SDK built from source with COGBox's patch
#   ./build.sh --configure     # only configure
#   ./build.sh --full          # build the whole game program (needs your own game copy)
#
# Why two modes: the released SDK is enough for everything except the renderer takeover, which
# needs `rex::graphics::DrawObserver` and the presenter changes that live in COGBox's own SDK
# patch (patches/rexglue-sdk.diff). Compiling against the release therefore stops in
# shadow_renderer.cpp. `--patched` points the build at sdk-patched-cg instead - the SDK that
# build_sdk.sh produced - and layer 0 then compiles completely.
#
# What still needs a game copy: the game program itself. codegen runs as part of that build and
# reads game/extracted/default.xex (your own disc image, per gow2_manifest.toml).
set -eu
cd "$(dirname "$0")"

# The Gears 2 source tree. This repository IS your fork clone (redcoat0726/COGBox-mac), so the
# tree lives right here as the Gears2-Native/ subdirectory. You edit it directly (it carries its
# own git history: origin=your-fork, upstream=Shagg). Override with COGBOX_NATIVE_SRC if you keep
# a separate checkout elsewhere.
TREE="${COGBOX_NATIVE_SRC:-../Gears2-Native}"
VULKAN_HEADERS=${VULKAN_HEADERS_DIR:-$PWD/third_party/vulkan-headers/include}
# Released SDK, unpacked from rexglue-sdk-<ver>-mac-arm64.zip. Supplies the prebuilt libraries.
PREFIX=${REXSDK_PREFIX:-$PWD/sdk}
# SDK built from source with COGBox's patch (build_sdk.sh). Optional.
# build_sdk.sh defaults to sdk-patched-cg - the full build with the recompiler library and CLI,
# which is what the game program needs. Passing SDK_TREE=sdk-patched builds layer 0 only (codegen
# left out), which is enough for layer 0 but cannot produce a game.
SDK_TREE=${REXSDK_TREE:-$PWD/sdk-patched-cg}

if [ ! -d "$TREE" ]; then
  echo "build.sh: $TREE is missing. The Gears 2 source is the Gears2-Native/ subdirectory" >&2
  echo "           of this repository (your fork clone redcoat0726/COGBox-mac)." >&2
  exit 1
fi

# The SDK header overlay is generated from COGBox's SDK patch rather than committed: it is rexglue SDK source
# (BSD-3-Clause), so redistributing it here would be shipping someone else's tree.
python3 tools/make_overlay.py >/dev/null

# macOS port: the release SDK has no WantsContinuousPaint(), so ImGuiDrawer asks the presenter
# for an extra UI paint on every frame that has any dialog. A permanent one such as the FPS bar
# then drives ~1900 extra paints a second and can wedge the Vulkan presenter (frozen picture,
# sound still running). sdk-patched-cg is gitignored, so reapply this override whenever that
# tree is rebuilt. Idempotent: the grep skips trees that already carry it.
IMGUI_PATCH="$PWD/$TREE/patches/sdk-macos-imgui-continuous-paint.diff"
if [ -d "$SDK_TREE/include/rex/ui" ] && \
   ! grep -q "WantsContinuousPaint" "$SDK_TREE/include/rex/ui/imgui_dialog.h" 2>/dev/null; then
  echo "== applying the macOS ImGui paint override to $SDK_TREE =="
  ( cd "$SDK_TREE" && patch -p1 --forward --no-backup-if-mismatch -i "$IMGUI_PATCH" )
fi

CONFIG_ONLY=0
TARGET=gn_layer0_xenos
PATCHED=0
TU6=0
for a in "$@"; do
  case "$a" in
    --configure) CONFIG_ONLY=1 ;;
    --full) TARGET="" ;;
    --patched) PATCHED=1 ;;
    --tu6) TU6=1; [ -n "${GN_GAME_VERSION:-}" ] || GN_GAME_VERSION=tu6 ;;
  esac
done

BUILD=build
SDK_ARGS="-DCMAKE_PREFIX_PATH=$PREFIX"
if [ "$PATCHED" = 1 ]; then
  if [ ! -f "$SDK_TREE/out/mac-arm64/librexruntime.dylib" ] && [ ! -f "$SDK_TREE/out/mac-arm64/librexruntimerd.dylib" ]; then
    echo "build.sh: $SDK_TREE has no built SDK - run ./build_sdk.sh first" >&2
    exit 1
  fi
  BUILD=build-patched
  # The TU6 build is a separate generation (generated/tu6) from a TU-patched default.xex, which is
  # the configuration COGBox actually tests: disc-only builds are no longer supported upstream.
  [ "$TU6" = 1 ] && BUILD=build-patched-tu6
  # REXSDK_DIR is a *source tree* to this project (cmake/rexglue.cmake add_subdirectory()s it),
  # which is exactly what the patched SDK is. The port's variables tell that tree to take its
  # third-party libraries from the release prefix instead of submodules.
  SDK_ARGS="-DREXSDK_DIR=$SDK_TREE -DREXGLUE_PORT_PREFIX=$PREFIX -DREXGLUE_PORT_PREBUILT=ON \
-DREXGLUE_USE_VULKAN=ON -DREXGLUE_BUILD_TESTS=OFF -DREXGLUE_ENABLE_TRACY=OFF \
-DCMAKE_CXX_FLAGS=-DGN_SDK_COGBOX_PATCH=1"
  echo "using the SDK built from source: $SDK_TREE"
  echo "game version: ${GN_GAME_VERSION:-base}$([ "${GN_GAME_VERSION:-base}" = tu6 ] && echo " (Title Update 6)")"
else
  echo "using the released SDK: $PREFIX"
fi

cmake -S "$TREE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  $SDK_ARGS \
  -DGN_GAME_VERSION="${GN_GAME_VERSION:-base}" \
  -DGN_HOST_VULKAN_HEADERS="$VULKAN_HEADERS" \
  -DGN_BUILD_TESTS="${GN_BUILD_TESTS:-OFF}"

[ "$CONFIG_ONLY" = 1 ] && exit 0

if [ -n "$TARGET" ]; then
  echo "building $TARGET (no game copy needed)"
  cmake --build "$BUILD" --target "$TARGET" -j "$(sysctl -n hw.ncpu)" -- -k
else
  echo "building everything (needs $TREE/game/extracted/default.xex)"
  cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"
fi
