import AppKit
import Testing
@testable import BitampKit

/// What VoiceOver finds in the skinned windows: their controls, by name and role, with
/// values that follow the player and actions that work.
@MainActor
@Suite struct AccessibilityTests {
    let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampAccessibility-\(UUID().uuidString)")!)
    let controller: PlaybackController

    init() {
        controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
    }

    func elements(_ view: SkinnedView) -> [SkinnedAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? SkinnedAccessibilityElement }
    }

    func element(_ view: SkinnedView, _ label: String) throws -> SkinnedAccessibilityElement {
        let all = elements(view)
        return try #require(all.first { $0.accessibilityLabel() == label } ?? all.first { $0.accessibilityLabel()?.hasPrefix(label) == true },
                            "no \(label)")
    }

    @Test func mainWindowNamesItsControls() throws {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        for label in ["Options", "Minimize", "Shade", "Quit Bitamp", "Previous", "Play", "Pause", "Stop", "Next", "Open Files",
                      "Position", "Volume", "Balance", "Shuffle", "Repeat", "Equalizer", "Playlist", "About Bitamp"] {
            #expect(labels.contains(label), "missing \(label)")
        }
        #expect(labels.contains { $0.hasPrefix("Visualizer") })
        #expect(try element(view, "Play").accessibilityRole() == .button)
        #expect(try element(view, "Shuffle").accessibilityRole() == .checkBox)
        #expect(try element(view, "Volume").accessibilityRole() == .slider)
        // Nothing is playing, so there's nothing to seek.
        #expect(try !element(view, "Position").isAccessibilityEnabled())
    }

    @Test func controlsAct() throws {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let shuffle = try element(view, "Shuffle")
        #expect(shuffle.accessibilityValue() as? Int == 0)
        #expect(shuffle.accessibilityPerformPress())
        #expect(controller.shuffle)
        #expect(shuffle.accessibilityValue() as? Int == 1)

        controller.volume = 0.5
        let volume = try element(view, "Volume")
        #expect(volume.accessibilityPerformIncrement())
        #expect(abs(controller.volume - 0.55) < 0.001)
        #expect(volume.accessibilityValueDescription() == "55%")

        controller.balance = 0
        let balance = try element(view, "Balance")
        #expect(balance.accessibilityValueDescription() == "Center")
        #expect(balance.accessibilityPerformDecrement())
        #expect(balance.accessibilityValueDescription() == "10% left")
    }

    /// Sliders are sliders to AppKit, so VoiceOver offers their steps, and they take a value.
    @Test func slidersCanBeSet() throws {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let balance = try element(view, "Balance")
        #expect(balance is NSAccessibilitySlider)
        #expect(balance.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilityValue(_:))))
        balance.setAccessibilityValue(NSNumber(value: 1.0))
        #expect(controller.balance == 1)
        let equalizer = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1)
        let band = try element(equalizer, "60 Hz")
        band.setAccessibilityValue(NSNumber(value: 0.75))
        #expect(controller.equalizer.bands[0] == 6)
        #expect(!(try element(view, "Play") is NSAccessibilitySlider))
    }

    /// VoiceOver goes through the controls as they're seen: row by row, left to right.
    @Test func readsRowByRow() {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        func before(_ a: String, _ b: String) -> Bool {
            (labels.firstIndex { $0.hasPrefix(a) } ?? .max) < (labels.firstIndex { $0.hasPrefix(b) } ?? .max)
        }
        #expect(before("Options", "Quit Bitamp"))
        #expect(before("Volume", "Balance"))
        #expect(before("Balance", "Equalizer"))
        #expect(before("Equalizer", "Playlist"))
        #expect(before("Playlist", "Position"))
        #expect(before("Position", "Previous"))
        #expect(before("Open Files", "Shuffle"))
        #expect(before("Shuffle", "Repeat"))
        #expect(before("Repeat", "About Bitamp"))
    }

    /// Window ▸ Cycle Through Windows goes top to bottom, then left to right.
    @Test func windowsCycleInReadingOrder() {
        func window(_ x: CGFloat, _ top: CGFloat) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: x, y: top - 100, width: 100, height: 100), styleMask: .borderless,
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            return window
        }
        let main = window(0, 900), equalizer = window(0, 800), playlist = window(0, 700), library = window(300, 900)
        defer { [main, equalizer, playlist, library].forEach { $0.orderOut(nil) } }
        let group = WindowGroup(main: main, panels: [.equalizer: equalizer, .playlist: playlist, .library: library],
                                defaults: UserDefaults(suiteName: "BitampCycle-\(UUID().uuidString)")!)
        #expect(group.window(after: main) === library)
        #expect(group.window(after: library) === equalizer)
        #expect(group.window(after: playlist) === main)
        #expect(group.window(after: main, backwards: true) === playlist)
    }

    /// The same element stays while its control does, so VoiceOver keeps its place.
    @Test func elementsStayTheSame() throws {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let play = try element(view, "Play")
        controller.volume = 0.2
        #expect(try element(view, "Play") === play)
    }

    @Test func followsTheOrbAndShadeLayouts() throws {
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin(theme: .orb))
        let orbLabels = elements(view).compactMap { $0.accessibilityLabel() }
        #expect(orbLabels.contains("Play"))
        #expect(!orbLabels.contains("Balance"), "the Orb has no balance slider")

        let classic = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        classic.setShaded(true)
        let shadeLabels = elements(classic).compactMap { $0.accessibilityLabel() }
        #expect(shadeLabels.contains("Unshade"))
        #expect(shadeLabels.contains("Play"))
        #expect(!shadeLabels.contains("Volume"))
        // Everything is inside the strip.
        for element in elements(classic) {
            #expect((element.control?.rect.maxY ?? .infinity) <= ShadeLayout.height)
        }
    }

    @Test func equalizerBandsSayTheirDecibels() throws {
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1)
        let band = try element(view, "60 Hz")
        #expect(band.accessibilityRole() == .slider)
        #expect(band.accessibilityValueDescription() == "0 dB")
        #expect(band.accessibilityPerformIncrement())
        #expect(controller.equalizer.bands[0] == 1)
        #expect(band.accessibilityValueDescription() == "+1.0 dB")
        #expect(try element(view, "1 kHz").accessibilityPerformDecrement())
        #expect(controller.equalizer.bands[4] == -1)
        #expect(try element(view, "Preamp").accessibilityPerformIncrement())
        #expect(controller.equalizer.preamp == 1)

        let on = try element(view, "Equalizer on")
        #expect(on.accessibilityValue() as? Int == 1)
        #expect(on.accessibilityPerformPress())
        #expect(!controller.equalizer.enabled)
        #expect(try !element(view, "Auto").isAccessibilityEnabled())
    }

    @Test func shadedEqualizerHasVolumeAndBalance() throws {
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.setShaded(true)
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        #expect(labels == ["Volume", "Balance", "Unshade", "Close"])
    }

    // MARK: - Playlist

    func playlist(songs: Int) -> PlaylistView {
        let urls = (1...songs).map { URL(fileURLWithPath: "/tmp/bitamp-a11y-\($0).mp3") }
        for (index, url) in urls.enumerated() {
            controller.info.seed(TrackMetadata(title: "Song \(index + 1)", artist: "The Low Bits", duration: 200), for: url)
        }
        controller.setQueueItems(urls, current: 1)
        return PlaylistView(controller: controller, preferences: preferences, skin: DefaultSkin())
    }

    func list(_ view: SkinnedView) throws -> SkinnedAccessibilityElement {
        try #require(elements(view).first { $0.accessibilityRole() == .list })
    }

    func key(_ code: UInt16, _ character: Int) -> NSEvent {
        let characters = String(UnicodeScalar(character)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func playlistIsAListOfTheSongsInView() throws {
        let view = playlist(songs: 40)
        let list = try list(view)
        #expect(list.accessibilityLabel() == "Playlist, 40 songs")
        let rows = (list.accessibilityChildren() ?? []).compactMap { $0 as? SkinnedAccessibilityElement }
        #expect(rows.count > 3 && rows.count < 40, "only the rows in view")
        #expect(rows.first?.accessibilityRole() == .row)
        #expect(rows.first?.accessibilityLabel() == "1. The Low Bits - Song 1, 3:20")
        #expect(rows[1].accessibilityLabel()?.hasSuffix(", current song") == true, "highlighted, but not playing")
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        for label in ["Add", "Remove", "Select", "Arrange", "Playlist File", "Play", "Close", "Shade"] {
            #expect(labels.contains(label), "missing \(label)")
        }
    }

    /// The playlist's own arrow keys move through the songs, and VoiceOver follows.
    @Test func voiceOverFollowsTheArrowKeys() throws {
        let view = playlist(songs: 40)
        view.keyDown(with: key(125, NSDownArrowFunctionKey))
        view.keyDown(with: key(125, NSDownArrowFunctionKey))
        let focused = try #require(view.accessibilityFocusedUIElement as? SkinnedAccessibilityElement)
        #expect(focused.accessibilityLabel()?.hasPrefix("2. ") == true)
        #expect(focused.isAccessibilitySelected())
        #expect(try list(view).accessibilitySelectedChildren()?.count == 1)
        // Far down the list, it's still a row VoiceOver can reach.
        view.keyDown(with: key(119, NSEndFunctionKey))
        let last = try #require(view.accessibilityFocusedUIElement as? SkinnedAccessibilityElement)
        #expect(last.accessibilityLabel()?.hasPrefix("40. ") == true)
    }

    @Test func songsCanBeMovedWithoutDragging() throws {
        let view = playlist(songs: 5)
        let rows = try list(view).accessibilityChildren()?.compactMap { $0 as? SkinnedAccessibilityElement } ?? []
        let first = try #require(rows.first)
        #expect(first.accessibilityCustomActions()?.map(\.name) == ["Play", "Remove", "Move Up", "Move Down"])
        let moveDown = try #require(first.accessibilityCustomActions()?.first { $0.name == "Move Down" })
        _ = moveDown.handler?()
        #expect(controller.queue.items[1].lastPathComponent == "bitamp-a11y-1.mp3")
        let focused = try #require(view.accessibilityFocusedUIElement as? SkinnedAccessibilityElement)
        #expect(focused.accessibilityLabel()?.hasPrefix("2. The Low Bits - Song 1") == true)
        // Pressing a row selects it, as in any Mac list; Return plays.
        #expect(rows[3].accessibilityPerformPress())
        #expect(view.selection == [3])
    }

    // MARK: - Expansion Paks

    @Test func cartridgesAndPlates() throws {
        let pak = A11yPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak], preferences: preferences))
        let view = PakView(controller: controller, skin: DefaultSkin(), scale: 1)
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains { $0.hasPrefix("Radio Pak, ") })
        let plate = try element(view, "Eject Radio Pak")
        #expect(plate.accessibilityPerformPress())
        #expect(!controller.paks.isInserted(pak))
        #expect(try element(view, "Insert Radio Pak").accessibilityLabel() == "Insert Radio Pak")
    }
}

extension AccessibilityTests {
    func draw(_ view: SkinnedView) {
        view.drawsAsActive = true
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    // MARK: - Media Library

    @Test func libraryHasSectionsAPageAndSearch() async throws {
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak]))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        for _ in 0..<200 where view.shown?.items.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        let lists = elements(view).filter { $0.accessibilityRole() == .list }
        #expect(lists.map { $0.accessibilityLabel() ?? "" }.first == "Sections")
        let page = try #require(lists.last)
        let rows = (page.accessibilityChildren() ?? []).compactMap { $0 as? SkinnedAccessibilityElement }.filter { $0.accessibilityRole() == .row }
        #expect(!rows.isEmpty)
        #expect(rows.first?.accessibilityCustomActions()?.map(\.name).contains("Add to Playlist") == true)
        let labels = elements(view).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Play") && labels.contains("Add"))
        // The search box is a real text field, named for what it's for.
        let field = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSTextField }.first)
        #expect(field.cell?.accessibilityLabel()?.hasPrefix("Search") == true)

        view.moveFocus(to: 1)
        let focused = try #require(view.accessibilityFocusedUIElement as? SkinnedAccessibilityElement)
        #expect(focused.isAccessibilitySelected())
        #expect(focused.accessibilityLabel() == rows[1].accessibilityLabel())
    }

    /// Once VoiceOver's cursor is in the sections, the arrow keys go through them, opening
    /// each, as in a Mac sidebar; Return goes into the page.
    @Test func arrowKeysFollowVoiceOverIntoTheSections() async throws {
        let pak = LibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak]))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        for _ in 0..<200 where view.shown?.items.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        let sections = try #require(elements(view).first { $0.accessibilityLabel() == "Sections" })
        let rows = (sections.accessibilityChildren() ?? []).compactMap { $0 as? SkinnedAccessibilityElement }.filter { $0.accessibilityRole() == .row }
        #expect(rows.map { $0.accessibilityLabel() ?? "" } == ["Albums", "Songs"])
        #expect(rows[0].isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilityFocused(_:))))

        rows[0].setAccessibilityFocused(true)
        #expect(view.keysInSections)
        view.keyDown(with: key(125, NSDownArrowFunctionKey))
        #expect(view.shown?.title == "Songs")
        #expect((view.accessibilityFocusedUIElement as? SkinnedAccessibilityElement)?.accessibilityLabel() == "Songs")

        for _ in 0..<200 where view.shown?.items.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        view.keyDown(with: key(36, 13))
        #expect(!view.keysInSections)
        #expect(view.focus == 0)
        #expect(view.shown?.title == "Songs")
    }

    // MARK: - Backstory

    @Test func backstoryReadsItsNotesAndSources() async throws {
        let service = CannedBackstory()
        service.updates = [.text("Words about the song."),
                           .cite([BackstorySource(title: "A history", url: URL(string: "https://lowbits.example/history")!)])]
        let store = BackstoryMemorySettings(defaults: UserDefaults(suiteName: "BitampA11yBackstory-\(UUID().uuidString)")!)
        let pak = BackstoryPak(providers: [.init(name: "Claude", models: ["Sonnet 5.5"]) { _, _ in service }], store: store)
        pak.save(["claude-key": "test-key"])
        let session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil))
        session.current = { (URL(string: "bitpak-test://track/1"), true) }
        session.describe = { _ in (PakNowPlaying(title: "Dial-Up Sunrise", artist: "The Low Bits"), nil) }
        let view = BackstoryView(session: session, paks: PakRegistry([pak]), skin: DefaultSkin(), scale: 1)
        session.update(active: true)
        for _ in 0..<50 { await Task.yield() }
        session.lookUp()
        for _ in 0..<50 { await Task.yield() }
        draw(view)
        let all = elements(view)
        let notes = try #require(all.first { $0.accessibilityRole() == .staticText && $0.accessibilityLabel()?.hasPrefix("Words") == true })
        #expect(notes.accessibilityLabel() == "Words about the song. [1]")
        let link = try #require(all.first { $0.accessibilityRole() == .link })
        #expect(link.accessibilityLabel() == "1: A history - lowbits.example")
        let auto = try element(view, "Auto")
        #expect(auto.accessibilityRole() == .checkBox)
        #expect(auto.accessibilityValue() as? Int == 0)
        #expect(auto.accessibilityPerformPress())
        #expect(pak.lookup == .everyTrack)
        #expect(all.contains { $0.accessibilityLabel() == "Service: Claude, Sonnet 5.5" })
        #expect(all.firstIndex(of: notes)! < all.firstIndex(of: link)!, "the notes, then their sources")
    }
}

/// A Pak with nothing in it, for the Paks window.
@MainActor
private final class A11yPak: Pak {
    let id = "radio"
    let name = "Radio"
    let schemes: Set<String> = ["radio-test"]
    let isAvailable = true
    let account = PakAccount.connected(name: nil)
    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}
