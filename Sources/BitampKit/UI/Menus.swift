import AppKit

/// Menus shared by the menu bar and the window's right-click menus.
/// Items have no target, so they go to the first responder, which is `MainView`.
@MainActor
enum Menus {
    static func playback() -> NSMenu {
        menu("Playback", [
            item("Previous", #selector(MainView.previousTrack(_:)), "z"),
            item("Play", #selector(MainView.play(_:)), "x"),
            item("Pause", #selector(MainView.pause(_:)), "c"),
            item("Stop", #selector(MainView.stop(_:)), "v"),
            item("Next", #selector(MainView.nextTrack(_:)), "b"),
            .separator(),
            item("Shuffle", #selector(MainView.toggleShuffle(_:)), "s"),
            item("Repeat", #selector(MainView.toggleRepeat(_:)), "r"),
            submenu(menu("Retro Sound", [
                choice("Off", #selector(MainView.setRetroSound(_:)), RetroSound.off),
                choice("8-Bit Crush", #selector(MainView.setRetroSound(_:)), RetroSound.crush),
            ])),
        ])
    }

    static func visualization() -> NSMenu {
        menu("Visualization", [
            choice("Spectrum Analyzer", #selector(MainView.setVisMode(_:)), VisMode.spectrum),
            choice("Oscilloscope", #selector(MainView.setVisMode(_:)), VisMode.oscilloscope),
            choice("Off", #selector(MainView.setVisMode(_:)), VisMode.off),
            .separator(),
            item("Show Peaks", #selector(MainView.togglePeaks(_:))),
            submenu(menu("Analyzer Falloff", Falloff.allCases.map {
                choice($0.rawValue.capitalized, #selector(MainView.setBarFalloff(_:)), $0)
            })),
            submenu(menu("Peak Falloff", Falloff.allCases.map {
                choice($0.rawValue.capitalized, #selector(MainView.setPeakFalloff(_:)), $0)
            })),
            submenu(menu("Oscilloscope Style", OscilloscopeStyle.allCases.map {
                choice($0.rawValue.capitalized, #selector(MainView.setOscilloscopeStyle(_:)), $0)
            })),
        ])
    }

    /// What right-clicking the window or clicking its options button shows.
    static func context() -> NSMenu {
        menu("Bitamp", [
            item("Open…", #selector(MainView.openFiles(_:)), "l"),
            .separator(),
            submenu(playback()),
            submenu(visualization()),
            .separator(),
            item("About Bitamp", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Quit Bitamp", #selector(NSApplication.terminate(_:)), "q", [.command]),
        ])
    }

    static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return menu
    }

    static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Bare-letter shortcuts by default, as on the classic players.
    static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// One option of a setting; the action reads the value back from `representedObject`.
    static func choice<T: RawRepresentable>(_ title: String, _ action: Selector, _ value: T) -> NSMenuItem
    where T.RawValue == String {
        let item = item(title, action)
        item.representedObject = value.rawValue
        return item
    }
}
