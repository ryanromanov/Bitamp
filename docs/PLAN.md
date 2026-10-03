# Bitamp: Phase 1 plan

## Context
The user wants an open-source, native macOS audio player in the style of classic Winamp 2.x: a small borderless skinned window, LCD time display, spectrum visualizer, chunky transport buttons. Decisions made so far:
- **Name:** Bitamp
- **Stack:** native Swift
- **License:** MIT
- **Legal:** no Winamp name, logo or artwork. The default skin is original art drawn in code. The layout mirrors the classic 275×116 geometry so `.wsz` skins can be loaded in a later phase.
- **Toolchain:** no Xcode. Build a Swift package from the terminal and bundle it into a `.app` with a script.

This plan covers **Phase 1**: a working main window that plays files. Later phases (playlist and EQ windows, `.wsz` loading, shade mode, signed releases) build on the same skin abstraction.

## Step 0: Prerequisite (the user runs this)
The installed Command Line Tools ship Swift 5.4 (2021), which is too old for the current macOS SDK. Update them without installing Xcode:
- `! softwareupdate --list`, then `! sudo softwareupdate -i "Command Line Tools for Xcode-<ver>"`
- or remove and reinstall with `! xcode-select --install`

Then confirm with `swift --version` (expect Swift 6.x).

## Project layout: `~/git/Bitamp/`
```
Package.swift                 swift-tools 5.9, macOS 13+, executable target "Bitamp"
Sources/Bitamp/
  main.swift                  NSApplication bootstrap
  AppDelegate.swift           menus: File > Open… (⌘O); Playback with Winamp keys Z/X/C/V/B; Quit
  Audio/PlayerEngine.swift    AVAudioEngine + AVAudioPlayerNode → AVAudioUnitEQ(10 bands, flat) → mixer
                              load(url), play/pause/stop, seek via scheduleSegment, volume, balance (pan),
                              position timer, metadata (title/artist, bitrate, sample rate, channels)
  Audio/SpectrumAnalyzer.swift  installTap on mixer → vDSP FFT (Accelerate) → 19 log-spaced bars with peak falloff
  Skin/Skin.swift             protocol: sprite(for: SkinElement) -> CGImage, plus text/digit glyphs.
                              SkinElement names mirror .wsz sprite names (MAIN_PLAY_BUTTON, POSBAR_THUMB, …)
  Skin/DefaultSkin.swift      original Bitamp art rendered procedurally with CoreGraphics at 1× pixel size
                              (beveled panels, green LCD, 7-segment digits, 5×6 pixel font)
  Skin/Layout.swift           classic main-window coordinates (rects for each control, from documented specs)
  UI/MainWindow.swift         borderless NSWindow, 275×116 logical at 2× (550×232), drag to move, always crisp
  UI/MainView.swift           NSView: draws sprites with nearest-neighbor scaling; hit-tests Layout rects;
                              pressed/hover states; drag-and-drop of audio files
  UI/Controls.swift           small button / toggle / slider models (volume, balance, position bar)
  UI/Marquee.swift            scrolling title text
Resources/Info.plist          bundle id dev.bitamp.Bitamp, audio CFBundleDocumentTypes (open via Finder/Dock)
scripts/bundle.sh             swift build -c release → Bitamp.app/Contents/{MacOS,Info.plist} → codesign -s - (ad hoc)
Tests/BitampTests/            time formatting, FFT-bin→bar mapping, layout hit-testing (if the CLT ships XCTest)
README.md  LICENSE (MIT)  .gitignore (.build/, .swiftpm/, *.app, DerivedData/)
```

## Phase 1 features
- Title bar with close and minimize; drag anywhere on the title bar to move the window
- LCD elapsed time (click to toggle remaining time), play/pause/stop indicator
- Scrolling "Artist – Title" marquee; kbps / kHz readouts; mono/stereo lights
- Spectrum visualizer (click to cycle spectrum → oscilloscope → off)
- Prev / Play / Pause / Stop / Next / Eject (Eject opens a file panel). Prev and Next restart the current track until the playlist exists in Phase 3
- Volume and balance sliders; seekable position bar
- Shuffle/Repeat toggles and EQ/PL buttons drawn but inactive (wired up in Phase 3)
- Opening files: drag-and-drop, File > Open, or Finder "Open With"

## Design notes
- **Skin abstraction first.** All drawing goes through `Skin`. Phase 4 adds a `WszSkin` that loads BMPs out of a `.wsz` zip, with no UI changes needed.
- **Pixel-perfect rendering.** Draw at 1× into the layer and scale 2× with `.nearest` filtering. All hit-testing uses 1× coordinates.
- **Engine owns no UI.** `PlayerEngine` publishes state through a small observable or delegate. `MainView` redraws on a ~30 fps display timer while playing.

## Repo setup
`git init`, then the first commit: "Initial Bitamp scaffold: classic main window and playback". Keep the repo local for now. Creating the GitHub repo with `gh` is a follow-up step for the user to OK.

## Verification
1. `swift build` compiles cleanly, and `swift test` passes if XCTest is available.
2. `scripts/bundle.sh`, then `open Bitamp.app`: the window appears at 550×232 with crisp pixels.
3. Make a test file with `say -o /tmp/... test.aiff "Bitamp test"` and `afconvert` it to m4a, plus any MP3 the user has. Check that it plays, pauses, stops, seeks, and that volume and balance work.
4. The visualizer moves with the audio, the time counts up, and the marquee scrolls.
5. Dragging a file onto the window, and "Open With" from Finder, both start playback.
6. Take a `screencapture -l <windowid>` screenshot to review the look.
