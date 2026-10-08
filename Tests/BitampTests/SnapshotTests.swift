import AppKit
import Foundation
import Testing
@testable import BitampKit

/// Renders the three windows to PNG files without touching the screen, for reviewing the
/// look. Off by default; run with `BITAMP_SNAPSHOTS=/some/folder scripts/test.sh`, and add
/// `BITAMP_SNAPSHOT_SKIN=/path/to/skin.wsz` to render a skin as well.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_SNAPSHOTS"] != nil))
struct SnapshotTests {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BITAMP_SNAPSHOTS"] ?? "/tmp")

    func save(_ view: NSView, _ name: String) throws {
        (view as? SkinnedView)?.drawsAsActive = true
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "BitampSnapshots-\(UUID().uuidString)")!)
    }

    func controller() -> PlaybackController {
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences())
        let names = ["Daft Punk - One More Time", "Röyksopp - Eple", "坂本龍一 - Merry Christmas Mr. Lawrence",
                     "Boards of Canada - Roygbiv", "The Avalanches - Since I Left You", "Aphex Twin - Xtal"]
        // Unopenable files are fine here: the list shows their names.
        controller.setQueueItems(names.map { URL(fileURLWithPath: "/nonexistent/\($0).mp3") })
        return controller
    }

    @Test func windows() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var skins: [(String, Skin)] = [("default", DefaultSkin()), ("millennium", DefaultSkin(theme: .millennium)), ("orb", DefaultSkin(theme: .orb))]
        if let path = ProcessInfo.processInfo.environment["BITAMP_SNAPSHOT_SKIN"] {
            skins.append(("wsz", try WszSkin(url: URL(fileURLWithPath: path))))
        }
        // The built-in skins as .wsz files too, to check them in other players.
        for theme in SkinTheme.builtIn {
            try WszWriter.write(DefaultSkin(theme: theme), to: folder.appendingPathComponent("\(theme.name).wsz"))
        }
        for (name, skin) in skins {
            let controller = controller()
            try save(MainView(controller: controller, preferences: preferences(), skin: skin), "\(name)-main")
            try save(EqualizerView(controller: controller, skin: skin, scale: 2), "\(name)-eq")
            try save(PlaylistView(controller: controller, preferences: preferences(), skin: skin), "\(name)-playlist")

            // Expansion Paks: one playing, one ejected, one slot empty; and the main window's badge.
            let paks = PakRegistry([SnapshotPak(id: "jukebox", name: "Jukebox"),
                                    SnapshotPak(id: "navidrome", name: "Navidrome")], preferences: preferences())
            paks.setInserted(false, paks.paks[1])
            let pakController = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: paks)
            pakController.enqueue([URL(string: "jukebox://song/1")!])
            let pakView = PakView(controller: pakController, skin: skin, scale: 2)
            for _ in 0..<20 { pakView.tick() }
            try save(pakView, "\(name)-paks")
            try save(MainView(controller: pakController, preferences: preferences(), skin: skin), "\(name)-main-pak")
            try save(EqualizerView(controller: pakController, skin: skin, scale: 2), "\(name)-eq-pak")

            // Four Paks: a second row.
            let many = PakRegistry(["Jukebox", "Demo", "Navidrome", "Internet Radio"].map {
                SnapshotPak(id: $0.lowercased().replacingOccurrences(of: " ", with: "-"), name: $0)
            }, preferences: preferences())
            let manyView = PakView(controller: PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: many),
                                   skin: skin, scale: 2)
            try save(manyView, "\(name)-paks-rows")

            // The shade strips.
            let views: [(String, SkinnedView)] = [
                ("main", MainView(controller: controller, preferences: preferences(), skin: skin)),
                ("eq", EqualizerView(controller: controller, skin: skin, scale: 2)),
                ("playlist", PlaylistView(controller: controller, preferences: preferences(), skin: skin)),
            ]
            for (window, view) in views {
                view.setShaded(true)
                try save(view, "\(name)-\(window)-shade")
            }
        }
    }
}

/// A Pak that "plays" anything in its scheme, for the Expansion Paks snapshots.
@MainActor
private final class SnapshotPak: Pak, PlaybackBackend {
    let id: String
    let name: String
    var schemes: Set<String> { [id] }
    let isAvailable = true
    let account = PakAccount.connected(name: nil)
    private(set) var state = PlaybackState.stopped
    private(set) var nowPlaying: NowPlaying?
    let currentTime: Double = 83
    let capabilities: PlaybackCapabilities = []
    var onTrackEnd: (() -> Void)?
    var onLoadFailure: ((Error) -> Void)?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { .backend(self) }

    func load(_ url: URL) throws {
        nowPlaying = NowPlaying(url: url, title: "Heroes (feat. Mindy Jones)", artist: "Moby", duration: 317)
    }
    func play() { state = .playing }
    func pause() {}
    func stop() { state = .stopped }
    func seek(to seconds: Double) {}
}
