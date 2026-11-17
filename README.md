# COGBox for macOS

> ## ⚠️ Work in progress — do not expect a finished game
>
> This tree builds, starts, and draws, but rendering is still being debugged (notably the
> depth-of-field / exposure path) and there is no confirmed playable state for any of the games.
> Treat it as a development tree. To actually play, use the original Windows
> [COGBox](https://github.com/Shagg88/COGBox) instead.
>
> **项目未完成。** 能编译、能启动、能出画，但画面还在调（景深 / 曝光），没有确认的可玩状态；
> 想玩游戏请用上游 Windows 版 COGBox。

An unofficial macOS port of [COGBox by Shagg](https://github.com/Shagg88/COGBox) — static
recompilation of the four Xbox 360 Gears of War games. Upstream is Windows-only; this repository
builds the launcher and the native game programs on Apple silicon with Vulkan (KosmicKrisp).

**This is an unofficial fork, not affiliated with the upstream author.** Upstream code is MIT,
Copyright (c) 2026 Shagg. See [LICENSE](LICENSE) and the `THIRD_PARTY_NOTICES.md` files inside each
game tree for the full licence picture.

## Building from source

There is no setup script, the same way upstream has none: you install the toolchain and the two SDKs
yourself, and the repository gives you build scripts. The full walkthrough is
**[docs/building-macos.md](docs/building-macos.md)** — this is the shape of it:

```sh
git clone https://github.com/redcoat0726/COGBox-mac.git && cd COGBox-mac

# 1. the SDKs, by hand (docs/building-macos.md, sections "The two rexglue SDKs" and "Vulkan SDK")
#    port/sdk/ + port/sdk-src/ + port/build_sdk.sh, and LunarG's Vulkan SDK for KosmicKrisp

# 2. the launcher and the app - minutes, needs no game copy
./build.sh && ./app/build_app.sh

# 3. your own copy: drag the ISO and its title update onto the app, then either let it build
#    the program automatically or run the same build yourself:
./port/build_game.sh gears2        # -> port/build-patched-tu6/gow2
```

Then `open build/COGBox.app` and press **Play**. What each step needs, and what goes wrong when one is
missing, is in [docs/building-macos.md](docs/building-macos.md); `./build/cogbox-mac port` reports
the same state on the command line.

## What is in here

| Path | What it is |
|---|---|
| `src/` | `cogbox-mac`: a small command-line tool that recognises, verifies and unpacks your own game copies, and starts the native ports. The filesystem core is upstream's `Gears2-Native/cogbox/src/x360fs.cpp`, compiled as it is. |
| `app/` | Native SwiftUI front end (the launcher window). |
| `port/` | Build/run scripts and the SDK adaptation that make the upstream game trees compile on macOS. |
| `Gears2-Native/`, `Gears3-Native/`, `GearsJ-Native/` | The three game source trees (this fork's copies of upstream, with our macOS changes committed in). |
| `tools/` | Upstream admin panel and Vulkan/SPIR-V diagnostics. |
| `docs/` | `building-macos.md` (this fork's build guide), `building.md` (upstream's Windows one, untouched), and upstream's HDR and modding notes. |

## What is **not** in here

No game data, disc images, title updates, recompiled game code (`generated/`), build output (`out/`),
the rexglue SDK, or the Vulkan SDK. All of those are gitignored; you must supply your own copy of each
game and build the SDK yourself. All three game source trees (Gears 2 / 3 / Judgment) are committed
with their macOS changes — no separate source snapshot is needed. **Even with all of that in place
the port is not playable yet** — see the warning at the top. Gears 2 is the primary target.

## Game data (not in git)

Your copy is unpacked into the game's own tree — `Gears2-Native/game/extracted/`, the title update in
`game/update/` (Judgment: `game/tu4/package/`) — exactly where upstream's builders keep it, and
`.gitignore` is what keeps it out of git. A fresh clone has source only; the one tracked file under any
`game/` is `Gears2-Native/game/README.txt`. The layout per game, the codegen input, and the
`--force` guard are in
[docs/building-macos.md](docs/building-macos.md#your-own-copy-of-the-game).

## Use

These commands are for **building and inspecting the port** — the window is the usual way to play:

```sh
./build/cogbox-mac doctor                             # check this Mac (GPU / Metal / Vulkan / Rosetta)
./build/cogbox-mac probe  ~/Desktop/gow2.iso           # is this the tested copy?
./build/cogbox-mac install ~/Desktop/gow2.iso          # -> <Game>-Native/game/extracted
./build/cogbox-mac status                             # what each game still needs
./build/cogbox-mac port                               # is the native build in place?
./build/cogbox-mac play --game gears2 --dry-run --json  # inspect the launch command
```

`play` locates the checkout automatically (walking up from the executable or the current
directory), so cloning into any directory works; `--repo <dir>` overrides it. `--lang <code>` picks
one of the 12 in-game COGBox UI languages, `--set name=value` overrides a launch switch, and
`--dry-run --json` prints the exact command without starting anything; dropping `--dry-run` starts
the native build.

## Following upstream

COGBox itself is still developed [upstream](https://github.com/Shagg88/COGBox). This fork keeps an
`upstream` remote pointing there; add it in your own clone and merge as you would any fork:

```sh
git remote add upstream https://github.com/Shagg88/COGBox.git
git fetch upstream && git merge upstream/main
```

Our macOS changes live in `src/`, `app/`, `port/` and the three game trees, so upstream merges need a
manual review — never copy an upstream tree over it.

Two files behave differently on a merge, on purpose:

- **`docs/building.md`** is upstream's file and is never edited here — `git diff upstream/main --
  docs/building.md` stays empty, so a merge can never conflict on it. The macOS build lives beside it
  in `docs/building-macos.md`.
- **`README.md`** is fork-specific: this file describes a macOS build with no release, so upstream's
  player-facing text would be wrong here. When a merge conflicts on it, keep this side
  (`git checkout --ours README.md`) — but read what upstream changed first, in case it is a licence or
  hosting change that matters to the fork.

## Status

**Work in progress, not finished.** Layer 0 and the game programs build on Apple silicon, and the
renderer's self-tests pass on a real GPU, but rendering fidelity is still being debugged (notably the
depth-of-field / exposure path). There is no confirmed playable state for any of the games.

The window shows the same three steps as COGBox's launcher — your copy, its title update, the native
program — and builds the program itself as soon as the first two are in place. `cogbox-mac status`
reports the same three from the command line.
