# COGBox for macOS

Hello — this is an unofficial macOS port of [COGBox](https://github.com/Shagg88/COGBox), Shagg's
native static recompilation of the Xbox 360 Gears of War games. Upstream builds for Windows; this
fork builds the same game programs, plus its own launcher, on Apple silicon with Vulkan through
LunarG's KosmicKrisp driver on Metal — no Wine, no emulator, no MoltenVK.

Upstream covers all four games. This fork currently builds **Gears of War 2**, **Gears of War 3**
and **Gears of War: Judgment**.

**This is an unofficial fork, not affiliated with the upstream author.** See [Legal](#legal) below.

> ## Work in progress — do not expect a finished game
>
> This tree builds, starts and draws, but rendering is still being debugged (notably the
> depth-of-field / exposure path) and there is no confirmed playable state for any of the games.
> Treat it as a development tree. To actually play, use the original Windows
> [COGBox](https://github.com/Shagg88/COGBox) instead.

## The games

| Game | Status on macOS |
|---|---|
| Gears of War 2 | Builds and starts; the primary target |
| Gears of War 3 | Builds and starts |
| Gears of War: Judgment | Builds and starts |

## What you need

- An Apple silicon Mac running macOS 13 or newer.
- Xcode command line tools and CMake 3.25+.
- LunarG's Vulkan SDK, and the rexglue SDK built with COGBox's patches.
- Your own copy of each game **and its title update**. No game files are included, ever.

## Building

The complete walkthrough — SDKs, DXC, game data, per-game build commands and the launcher — is in
**[docs/building-macos.md](docs/building-macos.md)**. Upstream's Windows guide is in
[docs/building.md](docs/building.md), kept exactly as Shagg wrote it.

`./build/cogbox-mac port` reports the same state on the command line: what is in place and what is
still missing.

## Running

```sh
open build/COGBox.app                                 # the window: drag a copy in, press Play
./build/cogbox-mac play --game gears2                 # the same start, from the terminal
./build/cogbox-mac status                             # copy / title update / program, per game
```

## What is in here

| Path | What it is |
|---|---|
| `src/` | `cogbox-mac`: recognises, verifies and unpacks your own copies, and starts the native ports. |
| `app/` | Native SwiftUI front end (the launcher window). |
| `port/` | Build/run scripts and the SDK adaptation that make the upstream game trees compile on macOS. |
| `Gears2-Native/`, `Gears3-Native/`, `GearsJ-Native/` | The three game source trees, with the macOS changes committed in. |
| `docs/` | This fork's macOS guide, upstream's Windows guide, and upstream's HDR and modding notes. |

## Following upstream

COGBox is still developed [upstream](https://github.com/Shagg88/COGBox). The macOS changes live in
`src/`, `app/`, `port/` and the three game trees, so an upstream merge needs a manual review —
never copy an upstream tree over it. `docs/building.md` is upstream's file and is never edited here;
the macOS guide lives beside it. `README.md` is fork-specific: when a merge conflicts on it, keep
this side, but read what upstream changed first in case it is a licence or hosting change that
matters here.

## Legal

This is an unofficial fan project. It is not affiliated with, endorsed by, or supported by
Microsoft, Epic Games or The Coalition.

"Gears of War", "Xbox" and "Xbox 360" are trademarks of Microsoft Corporation. The games and all of
their code, art, audio and other content are © Microsoft Corporation and their respective owners.
COGBox ships no game data: you must own a legitimate copy of each game and its title update, and the
launcher only unpacks and runs the files you supply. Please do not ask for or share game files.

The source code in this repository is MIT-licensed, Copyright (c) 2026 Shagg, with the macOS port
changes by the COGBox-mac contributors. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The port is provided as is, without warranty of
any kind.
