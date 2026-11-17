# Building COGBox for macOS

This is the macOS build: the launcher and the three game programs on Apple silicon, Vulkan through
LunarG's KosmicKrisp driver on Metal — no Wine, no emulator, no MoltenVK. Nothing is downloaded for
you, the same way nothing is downloaded for Windows.

Upstream's Windows build — Visual Studio, `tools\build.ps1`, the MinGW launcher — is in
[building.md](building.md), kept exactly as Shagg wrote it. Read it when you want to compare, not to
build here.

## Get the source

```sh
git clone https://github.com/redcoat0726/COGBox-mac.git
cd COGBox-mac
```

## What you need (macOS)

| | |
|---|---|
| Machine | Apple silicon, macOS 13 or newer. |
| Toolchain | Xcode **command line tools** (`xcode-select --install`) and **cmake 3.25+** (`brew install cmake`, or CMake.app with its command line tools installed). |
| Disk | About 25 GB: the SDK source and its build tree, `generated/`, and one unpacked game. |
| Vulkan SDK | LunarG **1.4.363.1** for macOS — see [Vulkan SDK](#vulkan-sdk) below. |
| Game | Your own copy of a game **and its title update** — disc image, Games on Demand, or an already-extracted folder. |

## The two rexglue SDKs

**1. Release SDK.** Unpack `rexglue-sdk-0.10.1-mac-arm64.zip` from
<https://github.com/rexglue/rexglue-sdk/releases/tag/v0.10.1> into `port/sdk/`. It supplies the
prebuilt libraries, the Vulkan **loader** and the headers. Then point the build at those headers:

```sh
cd port
mkdir -p third_party/vulkan-headers
ln -s ../../sdk/include third_party/vulkan-headers/include
```

`VULKAN_HEADERS_DIR` (e.g. `/opt/homebrew/include`) overrides that if you have the headers from
Homebrew instead.

**2. Source SDK with COGBox's patch.** The released SDK has no `rex::graphics::DrawObserver` and none
of the presenter changes the renderer takeover needs, so `shadow_renderer.cpp` does not compile
against it. This is the macOS equivalent of the patched install [building.md](building.md) describes
for Windows, done by one script:

```sh
git clone --recurse-submodules --branch v0.10.1 \
    https://github.com/rexglue/rexglue-sdk port/sdk-src
cd port && ./build_sdk.sh          # -> port/sdk-patched-cg/
```

`port/build_sdk.sh` applies `Gears2-Native/patches/rexglue-sdk.diff` plus the later portable patches
in number order, and imports the release SDK's prebuilt third-party libraries instead of building the
submodules. Expect tens of minutes to a few hours.

The prebuilt libraries are libraries only. Their headers are not all in the released SDK's `include/`
- glslang's, for one, are only in its source tree - so the **submodules are still required**: a clone
made without `--recurse-submodules` has `src/`, passes the first check, and then stops at
`glslang/Public/ShaderLang.h: No such file or directory`. The prebuilt import
(`port/sdk-thirdparty-prebuilt.cmake`) points the glslang targets at `thirdparty/glslang` for exactly
this reason. `build_sdk.sh` fetches the submodules itself when it finds them missing; to do it by
hand, or after a clone that failed halfway:

```sh
git -C port/sdk-src submodule update --init --recursive
```

The Vulkan SDK also ships glslang headers, and pointing at those instead looks tempting - they are not
the same build as the release SDK's `libglslang.a`, so expect link errors rather than a fix.

## Vulkan SDK

The download is an **installer**, not an SDK tree:

1. Download <https://sdk.lunarg.com/sdk/download/1.4.363.1/mac/vulkansdk-macos-1.4.363.1.zip> (about 400 MB).
2. Unzip it and double-click `vulkansdk-macOS-1.4.363.1.app`.
3. Accept the default location, `~/VulkanSDK/1.4.363.1`.

Nothing needs to be moved afterwards. The launcher finds the ICD in this order:

1. `tools/VulkanSDK/macOS/share/vulkan/icd.d/libkosmickrisp_icd.json` — a copy inside the checkout, if you keep one
2. `$VULKAN_SDK/share/vulkan/icd.d/libkosmickrisp_icd.json`
3. `~/VulkanSDK/macOS/...` and `~/VulkanSDK/<version>/macOS/...` — the installer's defaults

Leave `MaintenanceTool.app` in place — it uninstalls or repairs *this* installation. It is not the
upgrade path: LunarG ships each SDK version as its own installer, so upgrading means running the newer
installer (it lands in `~/VulkanSDK/<its version>`) and deleting the old folder whenever you like. With
several versions present the launcher picks the **newest**, so an upgrade needs no configuration.

For a scripted setup the same installer runs headless:

```sh
unzip -q vulkansdk-macos-1.4.363.1.zip -d /tmp/vk && cd /tmp/vk
./vulkansdk-macOS-1.4.363.1.app/Contents/MacOS/vulkansdk-macOS-1.4.363.1 \
    --accept-licenses --default-answer --confirm-command --root "$REPO/tools/VulkanSDK" install
```

## DXC (required)

The renderer's built-in shaders — rectangle-list fills, depth/colour resolves, the present blit — are
HLSL compiled at run time by **dxc**, so it is not optional. `port/third_party/dxc-macos/bin/dxc` is a
small stub: it loads `@rpath/libdxcompiler.dylib`, which must sit in
`port/third_party/dxc-macos/lib/`. Unpack both, or take them from the Vulkan SDK
(`macOS/bin/dxc` and `macOS/lib/libdxcompiler.dylib`).

A stub without its library is the quiet failure mode: every built-in shader fails to compile, and with
an empty shader cache the game never renders a frame — the startup movies look hung. `cogbox-mac port`
runs `dxc --version` and reports it, and `play` falls back to `$VULKAN_SDK/bin` or the SDK that supplied
the ICD when the checkout's own copy does not run.

## Building the launcher and the app

Needs only the command line tools — no game copy, no SDK:

```sh
./build.sh                 # the CLI            -> build/cogbox-mac
./app/build_app.sh         # the CLI + SwiftUI  -> build/COGBox.app
```

`./build.sh` on its own builds layer 0 against the release SDK and needs no game copy either.

## Your own copy of the game

`cogbox-mac install <copy>` — or dragging the file onto the app — unpacks into the game's own tree,
which is also where upstream keeps it. `.gitignore` is what keeps it out of git:

| Game | Unpacked disc | Title update | Codegen reads |
|---|---|---|---|
| Gears 2 | `Gears2-Native/game/extracted/` | `game/update/` | `game/tu6/patched/` |
| Gears 3 | `Gears3-Native/game/extracted/` | `game/update/` | `game/tu6/patched/` |
| Judgment | `GearsJ-Native/game/extracted/` | `game/tu4/package/` | `game/tu4/patched/` |

`install` unpacks the disc, unpacks the title update, and copies the pair codegen needs
(`default.xex` + `default.xexp`, ~20 MB) into `…/patched/` — the step upstream's `build.ps1 -Tu6`
does. An existing `patched/default.xex` is never replaced unless you pass `--force`: it may be the copy
the tree was built against and cannot be recovered from this repository.

```sh
./build/cogbox-mac probe   ~/Desktop/gow2.iso     # is this the tested copy? (size + SHA-1)
./build/cogbox-mac install ~/Desktop/gow2.iso     # -> Gears2-Native/game/extracted
./build/cogbox-mac install ~/Desktop/TU6.xexp     # -> Gears2-Native/game/update
```

`generated/` (the codegen output) is gitignored as well: the first full build creates it, it is
hundreds of MB per game, and it never travels with the repository.

## Building a game program

`port/build_game.sh` is the macOS counterpart of `tools\build.ps1` above — one game, one command:

| Game | Command | Output |
|---|---|---|
| Gears of War 2 (Title Update 6) | `./port/build_game.sh gears2` | `port/build-patched-tu6/gow2` |
| Gears of War 3 (Title Update 6) | `./port/build_game.sh gears3` | `port/build-gow3/gow3` |
| Gears of War: Judgment | `./port/build_game.sh judgment` | `port/build-gowj/gowj` |

It checks its prerequisites first (both SDKs, `game/extracted/default.xex`) and refuses to report
success without the program on disk. Gears 2 goes through `port/build.sh --patched --tu6 --full`; the
other two are their own CMake projects in their trees.

On a tree that has never been built it configures **twice**: `generated/<version>/sources.cmake` is
written by the codegen target *during* the build, and the include path for it is decided at configure
time. Configure, run the codegen target, configure again, then compile — otherwise the first build
stops at `gow*_init.h not found`.

## Running

```sh
open build/COGBox.app                                 # the window: drag a copy in, press Play
./build/cogbox-mac status                             # copy / title update / program, per game
./build/cogbox-mac play --game gears2                 # the same start, from the terminal
./build/cogbox-mac play --game gears2 --dry-run --json  # the exact command, without starting it
```

`play` locates the checkout by walking up from the executable or the current directory, so a clone
anywhere works; `--repo <dir>` overrides it. The first launch compiles shaders and can take a minute.
