# Expansion Paks

Optional add-ons that bring other music sources into Bitamp: Apple Music first, then servers such as Navidrome or Jellyfin, and maybe Spotify. The name comes from the N64's add-on slots. Together they are **Expansion Paks**; each one is a **Pak** ("Apple Music Pak"). In code they are `Pak`.

## Two kinds of source
1. **Stream Paks** turn a track into a URL or cached file that `PlayerEngine` plays as usual. The EQ, visualizer and Retro Sound all work. Fits Subsonic/Navidrome, Jellyfin, Plex and internet radio.
2. **Self-playing Paks** play the audio themselves. Bitamp sends play, pause, seek and next, and reads back the position and the end of each track. Apple Music (MusicKit; the tracks are copy-protected) and Spotify (only as a remote for its app) are this kind. The EQ and Retro Sound can't reach their audio, so the skin dims them. The visualizer can listen in: on macOS 14.2+, `PakAudioListener` taps the process playing the audio with a Core Audio process tap (for MusicKit, `com.apple.MediaPlayer.RemotePlayerService`) and feeds the analyzer.

## Host side
- **`PlaybackBackend`**: load, play, pause, stop, seek, state, current time, track end, and capabilities (`supportsEqualizer`, `supportsVisualizer`, `supportsRetroSound`). `PlayerEngine` becomes the local backend. `PlaybackController` picks a backend per queue item and moves between them at track changes.
- **Queue items stay URLs.** Pak tracks use the Pak's own scheme (`applemusic://song/1440857781`), so `PlayQueue`, the M3U session and the playlist window keep working. `TrackInfoStore` asks the Pak for title, artist and duration.
- **`Pak` protocol** (module `BitampPakKit`, protocols and value types only):
  - `id`, `name`, `schemes`, the minimum macOS version
  - account: status, `connect()` (sign in / authorize), `disconnect()`
  - browsing: search, library, playlists → `[PakTrack]` (URL + metadata)
  - `resolve(url)` → `.stream(URL)` or `.backend(PlaybackBackend)`
- **UI**: the **Media Library** (Window ▸ Media Library, ⌥L; File ▸ Browse <Pak>…, ⇧⌘A for the first) browses and searches one Pak and adds to the playlist; see below. The plain search panel it replaced is gone. The **Expansion Paks window** (Window ▸ Expansion Paks, ⌥K) shows each Pak as an N64-style cartridge in a slot: click it to browse it in the Media Library, click the slot's front plate to eject or insert it, right-click for a menu. Its frame borrows the playlist's title and side tiles, so `.wsz` skins dress it. While a Pak plays audio Bitamp can't see or hear (before macOS 14.2, or without permission to listen), the main window's visualizer shows a small cartridge and the Pak's name; clicking it opens the window. The playlist shows nothing extra.
- **Inserted or ejected**: every Pak starts inserted. Ejecting turns the service off: its tracks stay in playlists and the saved session, with their titles, but are skipped with "<NAME> PAK IS EJECTED", the Media Library closes if it shows it, and Bitamp doesn't contact it at all. Titles come from the playlist file (`#EXTINF`, read back since this change); a title never saved shows the track's ID until the Pak is inserted again.

## Packaging
- **Built-in Paks** are separate SwiftPM targets that depend only on `BitampPakKit` (`BitampAppleMusicPak`). The app registers them at launch, inserted. Apple Music has to be built in: MusicKit access is tied to the signed app's bundle ID (`com.ryanromanov.Bitamp`) and team.
- **Third-party Paks** (later) run as separate processes: a `.bitpak` bundle containing a helper executable that talks to Bitamp over JSON on stdin/stdout, installed into `~/Library/Application Support/Bitamp/Paks`. Running them in-process would mean turning off library validation in the hardened runtime and tying every Pak to Bitamp's Swift build. A separate process avoids both, survives a Pak crashing, and can be written in any language. Most third-party Paks are stream Paks, so the protocol can mostly return URLs plus metadata.

## Apple Music
- `ApplicationMusicPlayer` is in the macOS 14 SDK, but forum reports say playback may not work on macOS, especially outside the Mac App Store. The spike (`spikes/musickit`) tests this.
- **Spike results so far (2026-10-07, macOS 27.2, ad-hoc signed, no team):** authorization `.authorized`; subscription check works (`canPlayCatalogContent=true`); **library requests and library playback work** (audible; state, position, pause all report correctly); **catalog search fails with `developerTokenRequestFailed`**, as expected without a team signature. Still open: catalog search and catalog streaming from a Developer ID build with MusicKit enabled on the App ID. Fallbacks: MusicKit JS in a hidden web view (needs a developer token we sign, which lasts up to 6 months), or remote-controlling Music.app.
- Needs: MusicKit enabled for the `com.ryanromanov.Bitamp` App ID (developer portal → Identifiers → App Services), `NSAppleMusicUsageDescription` in Info.plist, Developer ID signing. The listener needs an Apple Music subscription to play catalog songs.
- Bitamp stays on macOS 13; the Apple Music Pak is checked at runtime and shows as unavailable before macOS 14.

## Media Library
A skinned browser, chosen over a native SwiftUI window (`MediaLibraryView`, `LibraryLayout`, `PixelTextBox`, `CoverCache`):
- The frame the Expansion Paks window wears (`PanelFrame`: the skin's `gen.bmp`, else the playlist's tiles). A search box and the Pak's sections (`.root`) on the left; on the right a bar with Back, the page's title, PLAY and ADD, then the page: an album or playlist's header, songs as rows, albums, artists and playlists as 44 px covers. A Pak that doesn't browse shows `search ""` and searches.
- Double-click opens a place or plays a song. PLAY and ADD take the selection, or with nothing selected, a whole album or playlist (`allTracks`). Right-click for Open, Play, Add. Arrow keys move through rows and covers (up and down keep to the column), Shift extends, Return opens or plays, Delete goes back, ⌘F or Tab to the search box. Songs, albums and playlists drag into the playlist where they're dropped (`MediaLibraryView.draggedItems`; the items stay with the view).
- More of a long section loads near the end of it. Back returns to where the page was scrolled. Loads carry a generation number, so a late answer about an earlier page is dropped.
- A panel in the window group (`.library`, layout name "LibraryWindow"): hidden by default, resizes from its bottom-right corner by the playlist's tiles (25 × 29), keeps its width across launches (`WindowGroup.place` takes a saved size), and the first time it opens off screen it goes beside the main window. Ejecting or removing its Pak empties and hides it. Left open at quit, it opens on the first Pak that can show it.
- It redraws only when something changes (`SkinnedView.redrawsEveryFrame`), or every frame while the search box is edited, for the caret. With it open the app went from 25–35% of a core to 15–19%; the rest is the playlist and main window, which redraw every frame.
- Covers are kept at the sizes drawn (44 and 64 px, averaged down from 3× that) in memory and in `~/Library/Caches/com.ryanromanov.Bitamp/Covers/<pak>`, found by Pak, artwork id and size, so a Pak's artwork ids must stay the same for the same picture. Apple Music's ids name what the art belongs to, since library art addresses change every time MusicKit is asked. Covers that scroll away stop loading.
- Not yet: accessibility (VoiceOver sees nothing in skinned windows), shade mode, remembering which Pak and section were open, Japanese input in the search box (untested).

Spike results (2026-10-16; artwork from `spikes/musickit --art`, the search box from a throwaway window not kept in the repo):
- **Artwork works.** Library items give `musicKit://` URLs that only `ArtworkImage` draws; captured from a never-shown window in 110–160 ms (some ~3 s, so load in the background and cache). Catalog items give https URLs plus background and text colors; library items have no colors. Covers shrink to 44 px by area averaging. Some library "albums" have empty titles and 16:9 art and need filtering and a square crop.
- **Search box: a hidden `NSTextField` with the canvas drawing it** in the pixel font (selection, marked text and caret from the field editor; clicks mapped to offsets with `ListFont` widths). Typing, selection, clipboard, dead keys and the emoji picker work; Japanese input untested.
- Text fields need Edit ▸ Undo/Redo/Cut/Copy/Paste in the main menu for their shortcuts (done, PR #31).

**Browsing** (`BitampPakKit/Browsing.swift`). One entry point for every page the window shows:
- `browse(_ location, after cursor) -> PakPage`. A location is `.root` (the sidebar, asked for each time the window opens, so playlists and the Apple Music group stay current), `.place(id)` or `.search(term)`.
- A `PakPage` is an optional `PakHeader` (title, subtitle, detail line, artwork) and `PakShelf`s, each an optional title and `PakItem`s: a `PakTrack`, or a `PakPlace` to open (`section`, `album`, `artist`, `playlist`). An album page is a header and one untitled shelf; an artist page has "Top Songs" and "Albums"; For You is a shelf per recommendation. The page's `cursor` gives more of its last shelf.
- `image(for: PakArtwork, size:)`: artwork is an opaque id the Pak hands out. The default fetches ids that are http(s) URLs; Apple Music captures `ArtworkImage` for library art.
- `allTracks(at:limit:)` follows cursors, for playing or adding a whole album or playlist.
- Paks that don't browse (`canBrowse` false) get defaults: `.search` gives their search's tracks, `.root` is empty. The requirements are declared in `protocol Pak` with defaults in an extension, so a Pak's own versions win through `any Pak`.
- Third-party Paks don't browse yet. When the window has settled the shape, the JSON protocol gets it without a version bump (0.6.1 refuses `protocol > 1`): advertised by an optional field in the hello reply, `browse` sent only to Paks that advertise it, artwork shaped like `PakSource` (`file`, or `url` with `headers`, for servers that need auth), defaults for new `PakProvider` methods, and `--check-pak` walking it.

**Apple Music browsing** (`AppleMusicBrowser`): Library (Recently Added, Albums, Artists, Songs, Playlists, 100 a page) and, with a subscription, Apple Music (For You, Recently Played, Top Charts). Places are `section/<name>` or `<library|catalog>-<album|artist|playlist>/<id>`. What MusicKit returned on a real library (`spikes/musickit --browse`, 2026-10-16):
- Most pages come back in 15–500 ms; For You takes ~1.7 s, search ~1 s. Covers average ~170–250 ms; about one in 35 never loads, even in a window ordered in off screen, and costs 6 s of trying.
- Long playlists come in batches of 100; pages follow them (up to 1,000 tracks).
- A fresh Pak, with nothing cached, opens every kind of saved place and looks up saved tracks, as after a relaunch.
- Recently Played takes at most 10 a request. Library search ignores its limit (109 songs for a limit of 25).
- Library and catalog ids are both often plain numbers, so a place keeps which it came from. Only playlists say: the listener's start `p.`, the catalog's `pl.`. For You and Recently Played can hold the listener's own playlists.
- Search drops the catalog's copies of what's in the library, but keeps both artists (the catalog's page has top songs), labelling the library's "In Library".

## Spotify
Since February 2026, Development Mode apps need a Premium owner and allow five users; extended access is for organizations with 250k+ monthly users. Spotify has no Mac SDK that plays audio in another app. At most this is a remote for the Spotify app. Last in line, maybe never.

## Order
1. Spike: sign in, search, and play one song with `ApplicationMusicPlayer` from a Developer ID–signed build.
2. `PlaybackBackend` and `BitampPakKit`, with local files as the built-in source. Nothing changes for users. **Done** (`Sources/BitampPakKit`, `PakRegistry`, `PakTests`). `.stream` only plays local files for now, since `PlayerEngine` reads through `AVAudioFile`; a stream Pak downloads to a cache file until the engine learns HTTP.
3. Apple Music Pak. **Built** (`Sources/BitampAppleMusicPak`, then File ▸ Add from Apple Music… ⇧⌘A, now the Media Library). Library search and playback tested through the spike's `--pak` mode: play, pause, resume, seek and the end of a song all work. Catalog search and streaming wait on the signed build. Notes:
   - Library songs report `duration` in milliseconds on macOS 27.2; `SongStore.duration(of:)` corrects it.
   - MusicKit doesn't announce the end of a song; the backend polls the player every 0.25 s and treats "stopped or paused within 1.5 s of the end" as the end. A pause from outside Bitamp (media keys) shows as paused.
   - Bitamp's volume and balance don't reach Apple Music: `ApplicationMusicPlayer` has no volume control.
   - Controls a Pak keeps out (capabilities `.volume`, `.equalizer`, `.retroSound`) are dimmed: the main window's volume and balance, the EQ window under its title bar, the EQ shade's sliders. Clicking or the keys flash why ("APPLE MUSIC PLAYS AT YOUR MAC'S VOLUME", "THE EQ CAN'T REACH APPLE MUSIC"); Retro Sound's choices grey out with a note at the top of the submenu. `PlaybackController.limitation(_:)` words them all.
4. ~~Expansion Paks tab in Preferences~~ The Expansion Paks window and the main window's Pak badge. **Done.**
5. Third-party Paks. **Done**: a framework plus a demo Pak, rather than Navidrome (the user's call). `BitampPakProtocol` (JSON lines over stdin/stdout), `BitampPakSDK` (`PakProvider` + `PakRunner`), `BitampDemoPak` (six public-domain tunes rendered as chiptunes, a waveform setting; `scripts/make-pak.sh` → `Demo.bitpak`). Host: `PakConnection` (process, request ids, 30 s timeout, restart, give up after 3 crashes a minute), `ExternalPak` (`.fetch` playback; downloads http(s) sources to the Pak's cache), `PakLibrary` (install with confirmation and quarantine removal, update by id, remove), `PakSettingsStore` (UserDefaults + Keychain), `PakSettingsPanel`. Install by double-click, drop on Bitamp, or File ▸ Install Expansion Pak…. The Paks window grows a row per three Paks. Author guide: [PAK-SDK.md](PAK-SDK.md). For authors: `Bitamp --check-pak <folder> [--setting k=v]` (`PakCheck`) runs a Pak through the manifest checks, `hello`, `search ""`, `track`, `resolve` and `shutdown` on the real `PakConnection`, with a 10 s timeout, a temporary cache, and stray stdout counted as a failure; `scripts/make-pak.sh [--universal] [target]` packages any Swift Pak, not only the demo.
6. Spotify as a remote, if at all.
