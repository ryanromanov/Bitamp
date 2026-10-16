import AppKit
import Foundation
import Testing
@testable import BitampKit

/// A Pak with a small invented library: Albums and Songs in its sidebar, eight albums of
/// four songs each, and covers drawn from each album's number.
@MainActor
final class LibraryPak: Pak {
    let id = "shelf"
    let name = "Shelf"
    let schemes: Set<String> = ["shelf"]
    var isAvailable = true
    let account = PakAccount.connected(name: nil)
    private(set) var browsed: [PakLocation] = []
    private(set) var imagesAsked = 0

    static let artists = ["Pixel Harbor", "The Low Bits", "Mira Vance", "Signal Lost"]
    static let albums = ["Neon Tide", "Dial-Up Sunrise", "Cassette Hearts", "Analog Weather",
                         "Midnight Modem", "Paper Planets", "Summer on Repeat", "Static Garden"]

    var canBrowse: Bool { true }

    func track(_ album: Int, _ number: Int) -> PakTrack {
        PakTrack(url: URL(string: "shelf://track/\(album)-\(number)")!, title: "Song \(number + 1) of \(Self.albums[album])",
                 artist: Self.artists[album % 4], duration: Double(150 + 13 * number), artwork: PakArtwork("cover-\(album)"))
    }

    func album(_ index: Int) -> PakPlace {
        PakPlace(id: "album/\(index)", kind: .album, title: Self.albums[index], subtitle: Self.artists[index % 4],
                 artwork: PakArtwork("cover-\(index)"))
    }

    func browse(_ location: PakLocation, after cursor: String?) async throws -> PakPage {
        browsed.append(location)
        switch location {
        case .root:
            return PakPage(shelves: [PakShelf(title: "Library", items: [
                .place(PakPlace(id: "section/albums", kind: .section, title: "Albums")),
                .place(PakPlace(id: "section/songs", kind: .section, title: "Songs")),
            ])])
        case .place("section/albums"):
            return PakPage(shelves: [PakShelf(items: (0..<8).map { .place(album($0)) })])
        case .place("section/songs"):
            return PakPage(shelves: [PakShelf(items: (0..<8).flatMap { a in (0..<4).map { .track(track(a, $0)) } })])
        case .place(let id) where id.hasPrefix("album/"):
            guard let index = Int(id.dropFirst(6)), Self.albums.indices.contains(index) else { throw PakBrowseError.notFound(id) }
            return PakPage(header: PakHeader(title: Self.albums[index], subtitle: Self.artists[index % 4],
                                             detail: "Electronic · 2025 · 4 songs", artwork: PakArtwork("cover-\(index)")),
                           shelves: [PakShelf(items: (0..<4).map { .track(track(index, $0)) })])
        case .search(let term):
            return PakPage(shelves: [
                PakShelf(title: "Songs", items: [.track(track(0, 0)), .track(track(1, 2))]),
                PakShelf(title: "Albums", items: [.place(album(0)), .place(album(3))]),
            ].filter { _ in !term.isEmpty })
        default:
            throw PakBrowseError.notFound("\(location)")
        }
    }

    /// Bands of two colors picked by the album's number.
    func image(for artwork: PakArtwork, size: Int) async -> CGImage? {
        imagesAsked += 1
        let number = Int(artwork.id.dropFirst(6)) ?? 0
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat(number) / 8
        context.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: size / 5, y: size / 5, width: size * 3 / 5, height: size * 3 / 5))
        return context.makeImage()
    }

    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.fileReadUnsupportedScheme) }
}

@MainActor @Suite struct MediaLibraryTests {
    func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "BitampLibrary-\(UUID().uuidString)")!)
    }

    /// Waits for the view's loads, which run on the main actor.
    func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func pagesAreLaidOutAsRowsAndCovers() {
        let pak = LibraryPak()
        let shelves = [
            PakShelf(title: "Songs", items: [.track(pak.track(0, 0)), .track(pak.track(0, 1))]),
            PakShelf(title: "Albums", items: (0..<8).map { .place(pak.album($0)) }),
        ]
        // Room for six covers across.
        let (blocks, height) = LibraryLayout.blocks(header: true, shelves: shelves, width: 340)
        #expect(blocks.map(\.kind) == [.header, .shelfTitle("Songs"), .track(0), .track(1),
                                       .shelfTitle("Albums"), .grid([2, 3, 4, 5, 6, 7]), .grid([8, 9])])
        #expect(blocks.last.map { $0.y + $0.height + 4 } == height)
        for (above, below) in zip(blocks, blocks.dropFirst()) { #expect(below.y >= above.y + above.height) }
    }

    @Test func theWindowGrowsByTiles() {
        #expect(LibraryLayout.snapped(LibraryLayout.defaultSize) == LibraryLayout.defaultSize)
        #expect(LibraryLayout.snapped(CGSize(width: 100, height: 50)) == LibraryLayout.minSize)
        #expect(LibraryLayout.snapped(CGSize(width: 512, height: 300)) == CGSize(width: 500, height: 293))
    }

    @Test func opensOnThePaksFirstSectionAndIntoAnAlbum() async throws {
        _ = NSApplication.shared
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: PakRegistry([pak]))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        try await settle { view.shown?.shelves.isEmpty == false }
        #expect(view.sidebar.map(\.title) == ["Library", "Albums", "Songs"])
        #expect(view.shown?.title == "Albums" && view.shown?.items.count == 8)
        #expect(pak.browsed == [.root, .place("section/albums")])
        // The same Pak again keeps where it was.
        view.show(pak)
        #expect(pak.browsed.count == 2)
    }

    @Test func playAddsAWholeAlbumWhenNothingIsSelected() async throws {
        _ = NSApplication.shared
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: PakRegistry([pak]))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        try await settle { view.shown?.items.isEmpty == false }
        let album = try #require(view.shown?.items.first?.place)
        view.open(album)
        try await settle { view.shown?.header != nil }
        #expect(view.shown?.title == "Neon Tide" && view.shown?.items.count == 4)
        view.playOrAdd(play: false)
        try await settle { controller.queue.count == 4 }
        #expect(controller.queue.items.map(\.absoluteString) == (0..<4).map { "shelf://track/0-\($0)" })
        #expect(controller.info.displayName(for: controller.queue.items[0]) == "Pixel Harbor - Song 1 of Neon Tide")
    }

    @Test func ejectingClearsItAndItStopsAsking() async throws {
        _ = NSApplication.shared
        let pak = LibraryPak()
        let paks = PakRegistry([pak])
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: paks)
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        try await settle { view.shown?.items.isEmpty == false }
        controller.setInserted(false, pak)
        view.clear()
        #expect(view.pak == nil && view.shown == nil && view.sidebar.isEmpty)
        let asked = pak.browsed.count
        view.show(pak)
        try await Task.sleep(for: .milliseconds(50))
        #expect(pak.browsed.count == asked)
    }

    func key(_ special: Int, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: String(UnicodeScalar(UInt32(special))!),
                         charactersIgnoringModifiers: String(UnicodeScalar(UInt32(special))!), isARepeat: false, keyCode: 0)!
    }

    /// Left and right go item by item; up and down keep to the column in rows of covers;
    /// Shift extends the selection.
    @Test func arrowKeysMoveThroughCovers() async throws {
        _ = NSApplication.shared
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: PakRegistry([pak]))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        try await settle { view.shown?.items.isEmpty == false }
        // Eight albums at the default width: a row of six, then two.
        view.keyDown(with: key(NSDownArrowFunctionKey))
        #expect(view.focus == 0 && view.selection == [0])
        view.keyDown(with: key(NSRightArrowFunctionKey))
        view.keyDown(with: key(NSRightArrowFunctionKey))
        #expect(view.focus == 2)
        view.keyDown(with: key(NSDownArrowFunctionKey))
        #expect(view.focus == 7, "the second row is shorter, so its last cover")
        view.keyDown(with: key(NSUpArrowFunctionKey))
        #expect(view.focus == 1)
        view.keyDown(with: key(NSRightArrowFunctionKey, shift: true))
        view.keyDown(with: key(NSRightArrowFunctionKey, shift: true))
        #expect(view.selection == IndexSet(1...3))
        view.keyDown(with: key(NSEndFunctionKey))
        #expect(view.focus == 7 && view.selection == [7])
    }

    /// Dropped in the playlist, songs go in as they are and albums as all their songs,
    /// where they were dropped.
    @Test func dropsGoWhereTheyFall() async throws {
        _ = NSApplication.shared
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences(), paks: PakRegistry([pak]))
        controller.setQueueItems([URL(string: "shelf://track/9-0")!, URL(string: "shelf://track/9-1")!])
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        try await settle { view.shown?.items.isEmpty == false }
        view.insert([.track(pak.track(5, 1)), .place(pak.album(2))], at: 1)
        try await settle { controller.queue.count == 7 }
        #expect(controller.queue.items.map(\.absoluteString) == ["shelf://track/9-0", "shelf://track/5-1", "shelf://track/2-0",
                                                                "shelf://track/2-1", "shelf://track/2-2", "shelf://track/2-3",
                                                                "shelf://track/9-1"])
        #expect(controller.info.displayName(for: controller.queue.items[1]) == "The Low Bits - Song 2 of Paper Planets")
    }

    /// A cover is asked of the Pak once: after that it comes from memory, and with a
    /// folder, from disk in a new cache, as after a relaunch.
    @Test func coversAreKept() async throws {
        let pak = LibraryPak()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BitampCovers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = CoverCache.Key(pak: pak.id, artwork: PakArtwork("cover-3"), size: 44)
        let first = CoverCache(folder: folder)
        #expect(first.cached(key) == nil)
        let image = try #require(await first.load(key, from: pak))
        #expect(image.width == 44 && image.height == 44)
        #expect(first.cached(key) != nil && pak.imagesAsked == 1)

        // The file is written in the background.
        let second = CoverCache(folder: folder)
        for _ in 0..<100 where second.cached(key) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.cached(key)?.width == 44)
        #expect(await second.load(key, from: pak) != nil && pak.imagesAsked == 1)
        // Without a folder, nothing is kept past the cache.
        #expect(CoverCache().cached(key) == nil)
    }

    /// The library starts hidden, even for people who used Bitamp before it existed; it
    /// comes back the size it was resized to; and the first time it opens, it's on screen.
    @Test func theWindowGroupKeepsItsSizeAndPlace() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "BitampLibraryWindow-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        func windows() -> (SkinnedWindow, SkinnedWindow, WindowGroup) {
            let main = SkinnedWindow(view: MainView(controller: controller, preferences: preferences, skin: DefaultSkin()),
                                     layoutName: "MainWindow", isMain: true)
            let library = SkinnedWindow(view: MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: preferences.scale),
                                        layoutName: "LibraryWindow", isMain: false)
            let group = WindowGroup(main: main, panels: [.library: library], defaults: defaults)
            group.restore()
            return (main, library, group)
        }
        let (main, library, group) = windows()
        defer { main.orderOut(nil); library.orderOut(nil) }
        #expect(!group.isVisible(.library))
        group.setVisible(.library, true)
        let screen = try #require((main.screen ?? NSScreen.main)?.visibleFrame)
        #expect(screen.contains(library.frame))

        let wider = CGSize(width: LibraryLayout.defaultSize.width + 50, height: LibraryLayout.defaultSize.height + 29)
        library.setContentSize(NSSize(width: wider.width * preferences.scale, height: wider.height * preferences.scale))
        group.saveLayout()
        let (main2, library2, _) = windows()
        defer { main2.orderOut(nil); library2.orderOut(nil) }
        #expect((library2.contentView as? SkinnedView)?.pixelSize == wider)
        #expect(library2.frame == library.frame)
    }
}
