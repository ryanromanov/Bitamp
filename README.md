# Bitamp

[![CI](https://github.com/ryanromanov/Bitamp/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanromanov/Bitamp/actions/workflows/ci.yml)

A small, open-source audio player for macOS with an old-school look: a tiny skinned window, a green LCD time display, a spectrum visualizer and chunky transport buttons, in the spirit of the classic desktop players from the late '90s.

> Status: early development.

Bitamp isn't affiliated with or endorsed by Winamp or Nullsoft. Its default skin is original artwork.

## Features

- Main window, 10-band equalizer and playlist, which snap together and move as a group. Window ▸ Main Window (⌥W) hides the main window and leaves the playlist, with its own little transport buttons, and Window ▸ Regroup Windows (⌥R) docks everything back into the classic stack
- Three built-in skins: Bitamp Default, the glossy Bitamp Millennium, and Bitamp Orb, whose main window drops the rectangle for a freeform shape with a big round play button. Classic `.wsz` skins work too: drop one on the window or use Skins ▸ Install Skin…. Skins ▸ Export Current Skin… saves any skin as a `.wsz` (the Orb exports as the rectangular Millennium layout).
- Shade mode for each window (double-click a title bar), and window sizes from 1× to 4×
- Spectrum and oscilloscope visualizer, shuffle and repeat, `.m3u` playlists
- Retro Sound (Playback ▸ Retro Sound, or T): an 8-bit crush that plays the song as 8-bit samples, or an experimental chiptune cover that transcribes the song, follows the sung melody for the lead, and plays it on pulse, triangle and noise voices, with some of the original mixed in if you like

## Download

Get the latest `Bitamp-x.y.z.zip` from [Releases](https://github.com/ryanromanov/Bitamp/releases). It runs on macOS 13 or later, on Apple Silicon and Intel. Bitamp isn't notarized yet, so the first time you open it, allow it under **System Settings → Privacy & Security → Open Anyway**.

## Build

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

```sh
swift build            # debug build
scripts/test.sh        # run tests (wraps swift test; see below)
scripts/bundle.sh      # release build → Bitamp.app (--universal, --version X.Y.Z)
open Bitamp.app
```

`scripts/test.sh` works around a Command Line Tools bug: an incremental test rebuild can fail with "plugin for module 'TestingMacros' not found". The script clears stale build state and retries, falling back to a clean build.

## License

MIT. See [LICENSE](LICENSE).

The chiptune mode transcribes notes with [Basic Pitch](https://github.com/spotify/basic-pitch) by Spotify, whose model ships in `Sources/BitampKit/Resources/BasicPitch` under the Apache License 2.0; its `LICENSE` and `NOTICE` are alongside it. It follows the sung melody with [MSNet](https://github.com/bill317996/Melody-extraction-with-melodic-segnet) by Bill Hsieh, Li Su and Yi-Hsuan Yang, whose model ships, converted to Core ML, in `Sources/BitampKit/Resources/MSNet` under the MIT License, with its `LICENSE`; `Sources/BitampKit/Audio/CFP.swift` ports its feature extraction. See `scripts/msnet/README.md`.
