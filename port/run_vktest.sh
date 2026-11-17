#!/bin/sh
# Run the Vulkan backend's self-test on this Mac's GPU.
#   ./run_vktest.sh
# Uses the same KosmicKrisp driver as the games (from the LunarG macOS Vulkan SDK under
# tools/VulkanSDK/). Expects ./sdk (the unpacked rexglue mac-arm64 release, for the loader)
# and a built ./build/gn_vktest (./build.sh).
set -eu
cd "$(dirname "$0")"
SDK=${REXSDK_DIR:-$PWD/sdk}
# KosmicKrisp ICD: this checkout's tools/VulkanSDK first, then $VULKAN_SDK, then the installer's
# default ~/VulkanSDK/<version>/macOS - the same order cogbox-mac uses.
kk_icd() {
    _rel=share/vulkan/icd.d/libkosmickrisp_icd.json
    for _d in "$PWD/../tools/VulkanSDK/macOS" "${VULKAN_SDK:-}"; do
        if [ -n "$_d" ] && [ -f "$_d/$_rel" ]; then echo "$_d/$_rel"; return 0; fi
    done
    # Newest installed version wins: a plain glob would rank 1.4.9 above 1.4.363.
    _dirs=$(ls -d "$HOME"/VulkanSDK/*/macOS 2>/dev/null | sort -rV 2>/dev/null)
    [ -n "$_dirs" ] || _dirs=$(ls -d "$HOME"/VulkanSDK/*/macOS 2>/dev/null)
    for _d in $_dirs; do
        if [ -f "$_d/$_rel" ]; then echo "$_d/$_rel"; return 0; fi
    done
    if [ -f "$HOME/VulkanSDK/macOS/$_rel" ]; then echo "$HOME/VulkanSDK/macOS/$_rel"; return 0; fi
    return 1
}
KK_ICD=${KOSMICKRISP_ICD:-$(kk_icd)}
[ -f "$KK_ICD" ] || { echo "run_vktest.sh: no KosmicKrisp ICD" >&2; exit 1; }
[ -x build/gn_vktest ] || { echo "build/gn_vktest missing - run ./build.sh first" >&2; exit 1; }
[ -f "$KK_ICD" ] || { echo "no KosmicKrisp ICD at $KK_ICD - unpack the LunarG macOS Vulkan SDK into tools/VulkanSDK/" >&2; exit 1; }
DYLD_LIBRARY_PATH="$SDK/lib" \
VK_DRIVER_FILES="$KK_ICD" \
  ./build/gn_vktest "$@" 2>/dev/null | grep -vE '^\t' | tail -40
