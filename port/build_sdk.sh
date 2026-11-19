#!/bin/sh
# Build the rexglue SDK from source with COGBox's SDK patch applied.
#
# Why this exists: COGBox's renderer takeover needs an SDK that has `draw_observer` and a
# presenter that reports `resource_uav_capable`. Those live in COGBox's own SDK patch
# (`patches/rexglue-sdk.diff`, 56 files / 4371 lines), which the released SDK does not carry.
# Compiling COGBox against the release therefore stops at shadow_renderer.cpp; the only way
# past it is an SDK built from source with that patch.
#
#   ./build_sdk.sh              # patch + configure + build
#   ./build_sdk.sh --configure  # stop after configuring
#
# Inputs (see README):
#   sdk-src/     rexglue SDK source tree (git clone --recurse-submodules --branch v0.10.1, see README)
#   sdk/         the release mac-arm64 SDK unpacked (prebuilt third-party libs and headers)
set -eu
cd "$(dirname "$0")"

SRC=${SDK_SRC:-sdk-src}
TREE=${SDK_TREE:-sdk-patched-cg}
BUILD=${SDK_BUILD:-sdk-build}
PREFIX=${REXSDK_PREFIX:-$PWD/sdk}
REF=${SDK_REF:-v0.10.1}
DIFF=../Gears2-Native/patches/rexglue-sdk.diff

[ -d "$SRC/src" ] || { echo "build_sdk.sh: $SRC is missing or incomplete - git clone --recurse-submodules --branch v0.10.1 https://github.com/rexglue/rexglue-sdk $SRC" >&2; exit 1; }
[ -f "$PREFIX/lib/librexruntime.dylib" ] || { echo "build_sdk.sh: $PREFIX does not look like the rexglue release" >&2; exit 1; }
[ -f "$DIFF" ] || { echo "build_sdk.sh: $DIFF missing - it lives in Gears2-Native/patches (this repo's fork tree)" >&2; exit 1; }

# Submodules: the release SDK ships the third-party *libraries*, not every header. glslang's headers live only in its
# source tree, so a clone made without --recurse-submodules has src/ (so it passes the check above) and then stops
# deep in the build at "glslang/Public/ShaderLang.h: No such file". Fetch the submodules here, once, rather than
# leaving that to be diagnosed from a compiler error.
if [ ! -f "$SRC/thirdparty/glslang/glslang/Public/ShaderLang.h" ]; then
  if [ -d "$SRC/.git" ]; then
    echo "== SDK submodules are missing (glslang's headers are among them) - fetching =="
    git -C "$SRC" submodule update --init --recursive
  fi
  if [ ! -f "$SRC/thirdparty/glslang/glslang/Public/ShaderLang.h" ]; then
    echo "build_sdk.sh: $SRC/thirdparty/glslang is missing." >&2
    echo "  The release SDK's prebuilt libraries do not include glslang's headers; its source tree does." >&2
    echo "  Fix: git -C $SRC submodule update --init --recursive" >&2
    exit 1
  fi
fi

# --- 1. fresh working copy ---------------------------------------------------------------------
if [ ! -d "$TREE" ]; then
  echo "== copying sources to $TREE =="
  mkdir -p "$TREE"
  # .git is 150 KB of promisor metadata and useless here; everything else comes along.
  (cd "$SRC" && find . -mindepth 1 -maxdepth 1 ! -name .git -exec cp -R {} "../$TREE/" \;)
fi

# --- 2. apply COGBox's SDK patch ---------------------------------------------------------------
# Against v0.10.1 - the version COGBox actually pins (nightly-20261002-bd833a2a) - all 56 file
# sections apply cleanly. Against v0.10.0 exactly one file conflicts: src/input/input_system.cpp
# adds a lock_guard to UpdateConnectedUser/GetStateForUI, two functions that only exist from
# v0.10.1 on. v0.10.0 is not a supported source tree (its API is missing things the port calls,
# such as InputSystem::GetStateForUI); the single known reject is tolerated so an old tree fails
# later and louder rather than here.
if [ ! -f "$TREE/.rexglue-sdk-patched" ]; then
  echo "== applying COGBox's SDK patch =="
  ( cd "$TREE" && patch -p1 --forward --no-backup-if-mismatch -i "../$DIFF" >/tmp/sdk_patch.log 2>&1 || true )
  rejects=$(find "$TREE" -name '*.rej' | wc -l | tr -d ' ')
  echo "   rejects: $rejects"
  if [ "$rejects" != "0" ]; then
    find "$TREE" -name '*.rej' | sed "s|^$TREE/|   |"
    # Refuse to continue on anything beyond the known input_system.cpp hunks: a silent partial
    # patch would be much harder to debug than a stop here.
    unexpected=$(find "$TREE" -name '*.rej' ! -name 'input_system.cpp.rej' | wc -l | tr -d ' ')
    if [ "$unexpected" != "0" ]; then
      echo "build_sdk.sh: unexpected rejects beyond input_system.cpp - stopping" >&2
      exit 1
    fi
  fi
  find "$TREE" -name '*.rej' -delete
  touch "$TREE/.rexglue-sdk-patched"
fi

# --- 2b. the later, independent COGBox SDK patches -------------------------------------------------
# rexglue-sdk.diff is only patches 1-37. The Windows launcher's settings expect cvars from the
# later patches, which are separate diffs applied in number order on top of it. These are the ones
# that are portable and actually back a launcher control; see patches/README.md for the full list.
#   38  pad_look_scale / pad_look_deadzone   (55 builds on its input_system.cpp block)
#   45  XGetLanguage reads user_language     (game's own localisation)
#   47  user_game_region                    (bare filenames: -p0 from src/kernel/xam)
#   49b net_system_link / net_peer_ip       (POSIX branch on macOS; 50 builds on it)
#   54  user_gamertag
#   55  pad_remap / pad_radial_deadzone     (after 38)
#   60  keybind_walk / mnk_walk_*          (after 59; none of 56-59 is needed here)
#  116  Vulkan pipeline libraries          (0.6.5; shadow_renderer.cpp calls the two free functions)
# Skipped on purpose: 39/40 (bare filenames, unrelated input/audio fixes), 41-44, 46, 48, 52, 53,
# 56-67 (diagnostics, save/online fixes), 95-115 (online/kernel/input; the 0.6.5 game code does
# not call them, and 113/113b/115 expect the unapplied 95-112 line), and 66 (Windows-only volume
# mixer).
EXTRA_MARK="$TREE/.cogbox-extra-patches"
if [ ! -f "$EXTRA_MARK" ]; then
  PATCHES="$(cd "$(dirname "$0")" && pwd)/../Gears2-Native/patches"
  TREE_ABS="$(cd "$TREE" && pwd)"
  apply_p1() {
    echo "   applying $1"
    ( cd "$TREE_ABS" && patch -p1 --forward --no-backup-if-mismatch -i "$PATCHES/$1" ) || return 1
  }
  (
    set -e
    apply_p1 sdk-patch38-pad-look.diff
    apply_p1 sdk-patch45-xgetlanguage.diff
    # 47 is the third patch with bare filenames (README only documents 39 and 40).
    echo "   applying sdk-patch47-game-region.diff (-p0)"
    ( cd "$TREE_ABS/src/kernel/xam" && patch -p0 --forward --no-backup-if-mismatch \
        -i "$PATCHES/sdk-patch47-game-region.diff" )
    apply_p1 sdk-patch49b-system-link.diff
    apply_p1 sdk-patch50-system-link-peers.diff
    apply_p1 sdk-patch54-user-gamertag.diff
    apply_p1 sdk-patch55-pad-layout.diff
    apply_p1 sdk-patch60-walk-key.diff
    apply_p1 sdk-patch61-present-pipeline-format.diff
    apply_p1 sdk-patch94-macos-input-stubs.diff
    # 0.6.5's shadow_renderer.cpp links against these two (SDK runtime 066).
    apply_p1 sdk-patch116-vulkan-pipeline-library.diff
  ) || { echo "build_sdk.sh: a later SDK patch failed; see the output above" >&2; exit 1; }
  touch "$EXTRA_MARK"
  echo "   later SDK patches applied"
fi

# --- 3. third-party dependencies: import the prebuilt ones --------------------------------------
cp sdk-thirdparty-prebuilt.cmake "$TREE/thirdparty/CMakeLists.txt"

# --- 4. edits to upstream's build files ---------------------------------------------------------
# Skipping the install rules (CMake will not install an imported target, nor export a target that
# links one) and putting thirdparty/vendor-headers - nlohmann/json and inja, both single headers -
# on the include path. Kept in a script rather than inline: nested heredocs in shell are exactly
# where escaping bugs hide.
# Codegen is built: it compiles fine against v0.10.1 (it did not against 0.10.0, which is why this
# used to be opt-in). SDK_SKIP_CODEGEN=1 leaves it out.
CODGEN_FLAG=""
[ "${SDK_SKIP_CODEGEN:-0}" = "1" ] && CODGEN_FLAG="--skip-codegen"
python3 tools/prepare_sdk_tree.py "$TREE" $CODGEN_FLAG

# --- 4. configure -------------------------------------------------------------------------------
CONFIG_ONLY=0
[ "${1:-}" = "--configure" ] && CONFIG_ONLY=1

echo "== configuring =="
cmake -S "$TREE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DREXGLUE_PORT_PREFIX="$PREFIX" \
  -DREXGLUE_PORT_PREBUILT=ON \
  -DREXGLUE_BUILD_TESTS=OFF \
  -DREXGLUE_ENABLE_TRACY=OFF \
  -DREXGLUE_USE_VULKAN=ON
[ "$CONFIG_ONLY" = 1 ] && exit 0

# --- 5. build ------------------------------------------------------------------------------------
echo "== building =="
# `-k` is a switch for make (keep going), not a flag taking a count - unlike ninja's -k 0.
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)" -- -k
