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
        // Frames are inside the strip.
        for element in elements(classic) {
            #expect(element.accessibilityFrameInParentSpace().maxY <= classic.bounds.height + 0.5)
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
}
