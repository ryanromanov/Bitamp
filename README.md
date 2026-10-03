# Bitamp

A small, open-source audio player for macOS with an old-school look: a tiny skinned window, a green LCD time display, a spectrum visualizer and chunky transport buttons, in the spirit of the classic desktop players from the late '90s.

> Status: early development.

Bitamp isn't affiliated with or endorsed by Winamp or Nullsoft. Its default skin is original artwork.

## Build

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

```sh
swift build            # debug build
scripts/test.sh        # run tests (wraps swift test; see below)
scripts/bundle.sh      # release build → Bitamp.app
open Bitamp.app
```

`scripts/test.sh` works around a Command Line Tools bug: an incremental test rebuild can fail with "plugin for module 'TestingMacros' not found". The script clears the stale module cache and retries.

## License

MIT. See [LICENSE](LICENSE).
