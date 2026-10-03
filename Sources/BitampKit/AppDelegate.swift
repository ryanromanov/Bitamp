import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
    private var windowGroup: WindowGroup?
    private var mainView: MainView?

    public override init() {
        super.init()
    }

    // The windows are built before launch finishes, because Finder's "Open With"
    // delivers files before applicationDidFinishLaunching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let skin = DefaultSkin()

        let mainView = MainView(controller: controller, preferences: preferences, skin: skin)
        mainView.onOpen = { [weak self] in self?.openDocument(nil) }
        controller.onError = { [weak mainView] message in
            NSSound.beep()
            mainView?.flash(message)
        }
        let equalizerView = EqualizerView(controller: controller, skin: skin)
        let playlistView = PlaylistView(controller: controller, preferences: preferences, skin: skin)
        playlistView.keyFallback = mainView
        for view in [equalizerView, playlistView] as [SkinnedView] {
            view.announce = mainView.announce
        }

        let main = SkinnedWindow(view: mainView, autosaveName: "BitampMainWindow", isMain: true)
        if !main.setFrameUsingName("BitampMainWindow") { main.center() }
        let group = WindowGroup(main: main, panels: [
            .equalizer: SkinnedWindow(view: equalizerView, autosaveName: "BitampEqualizerWindow", isMain: false),
            .playlist: SkinnedWindow(view: playlistView, autosaveName: "BitampPlaylistWindow", isMain: false),
        ])
        for view in [mainView, equalizerView, playlistView] as [SkinnedView] {
            view.windowGroup = group
        }
        self.mainView = mainView
        windowGroup = group

        controller.restoreSession()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        windowGroup?.main.makeKeyAndOrderFront(nil)
        windowGroup?.restore()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller.saveSession()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        controller.open(urls)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .folder] + ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.open(panel.urls)
    }

    @objc private func minimize(_ sender: Any?) {
        windowGroup?.main.miniaturize(sender)
    }

    @objc private func toggleEqualizer(_ sender: Any?) {
        windowGroup?.toggle(.equalizer)
    }

    @objc private func togglePlaylist(_ sender: Any?) {
        windowGroup?.toggle(.playlist)
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = Menus.menu("Bitamp", [
            Menus.item("About Bitamp", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            Menus.item("Hide Bitamp", #selector(NSApplication.hide(_:)), "h", [.command]),
            Menus.item("Quit Bitamp", #selector(NSApplication.terminate(_:)), "q", [.command]),
        ])

        let open = Menus.item("Open…", #selector(openDocument(_:)), "o", [.command])
        open.target = self
        let fileMenu = Menus.menu("File", [open])

        // Select All reaches the playlist when it has focus.
        let editMenu = Menus.menu("Edit", [
            Menus.item("Select All", #selector(NSResponder.selectAll(_:)), "a", [.command]),
        ])

        // The classic shortcuts: Alt+G for the equalizer and Alt+E for the playlist.
        let equalizer = Menus.item("Equalizer", #selector(toggleEqualizer(_:)), "g", [.option])
        let playlist = Menus.item("Playlist", #selector(togglePlaylist(_:)), "e", [.option])
        let minimize = Menus.item("Minimize", #selector(minimize(_:)), "m", [.command])
        for item in [equalizer, playlist, minimize] { item.target = self }
        let windowMenu = Menus.menu("Window", [equalizer, playlist, .separator(), minimize])
        NSApp.windowsMenu = windowMenu

        return Menus.menu("", [appMenu, fileMenu, editMenu, Menus.playback(), Menus.visualization(), windowMenu]
            .map(Menus.submenu))
    }
}

extension AppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleEqualizer(_:)): item.state = windowGroup?.isVisible(.equalizer) == true ? .on : .off
        case #selector(togglePlaylist(_:)): item.state = windowGroup?.isVisible(.playlist) == true ? .on : .off
        default: break
        }
        return true
    }
}
