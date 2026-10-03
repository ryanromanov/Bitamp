# Bitamp

A small, open-source audio player for macOS with an old-school look: a tiny skinned window, a green LCD time display, a spectrum visualizer and chunky transport buttons, in the spirit of the classic desktop players from the late '90s.

> Status: early development.

Bitamp isn't affiliated with or endorsed by Winamp or Nullsoft. Its default skin is original artwork.

## Features

- Main window, 10-band equalizer and playlist, which snap together and move as a group
- Classic `.wsz` skins: drop one on the window or use Skins ▸ Install Skin…
- Shade mode for each window (double-click a title bar), and window sizes from 1× to 4×
- Spectrum and oscilloscope visualizer, shuffle and repeat, `.m3u` playlists

## Build

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

```sh
swift build            # debug build
scripts/test.sh        # run tests (wraps swift test; see below)
scripts/bundle.sh      # release build → Bitamp.app
open Bitamp.app
```

`scripts/test.sh` works around a Command Line Tools bug: an incremental test rebuild can fail with "plugin for module 'TestingMacros' not found". The script clears stale build state and retries, falling back to a clean build.

## License

MIT. See [LICENSE](LICENSE).
