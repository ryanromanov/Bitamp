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
        var skins: [(String, Skin)] = [("default", DefaultSkin()), ("millennium", DefaultSkin(theme: .millennium))]
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
