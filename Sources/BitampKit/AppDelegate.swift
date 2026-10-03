import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
    private var windowGroup: WindowGroup?
    private var mainView: MainView?
    private var views: [SkinnedView] = []
    private let skinsMenu = NSMenu(title: "Skins")

    public override init() {
        super.init()
    }

    // The windows are built before launch finishes, because Finder's "Open With"
    // delivers files before applicationDidFinishLaunching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let skin = savedSkin()

        let mainView = MainView(controller: controller, preferences: preferences, skin: skin)
        mainView.onOpen = { [weak self] in self?.openDocument(nil) }
        mainView.onSkinDropped = { [weak self] url in self?.installSkin(url) }
        controller.onError = { [weak mainView] message in
            NSSound.beep()
            mainView?.flash(message)
        }
        let equalizerView = EqualizerView(controller: controller, skin: skin, scale: CGFloat(preferences.scale))
        let playlistView = PlaylistView(controller: controller, preferences: preferences, skin: skin)
        playlistView.keyFallback = mainView
        for view in [equalizerView, playlistView] as [SkinnedView] {
            view.announce = mainView.announce
        }

        let main = SkinnedWindow(view: mainView, autosaveName: "BitampMainWindow", isMain: true)
        let group = WindowGroup(main: main, panels: [
            .equalizer: SkinnedWindow(view: equalizerView, autosaveName: "BitampEqualizerWindow", isMain: false),
            .playlist: SkinnedWindow(view: playlistView, autosaveName: "BitampPlaylistWindow", isMain: false),
        ])
        views = [mainView, equalizerView, playlistView]
        for view in views {
            view.windowGroup = group
        }
        self.mainView = mainView
        windowGroup = group

        controller.restoreSession()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        windowGroup?.restore()
        windowGroup?.main.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller.saveSession()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if let skin = urls.first(where: SkinLibrary.isSkin) {
            installSkin(skin)
        } else {
            controller.open(urls)
        }
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

    // MARK: - Skins

    private func savedSkin() -> Skin {
        guard let name = preferences.skinName, let url = SkinLibrary.url(named: name),
              let skin = try? WszSkin(url: url)
        else { return DefaultSkin() }
        return skin
    }

    private func apply(_ skin: Skin, named name: String?) {
        preferences.skinName = name
        for view in views { view.skin = skin }
        mainView?.flash("SKIN: \(name ?? "BITAMP DEFAULT")", for: 2)
    }

    private func installSkin(_ url: URL) {
        do {
            let installed = try SkinLibrary.install(url)
            apply(try WszSkin(url: installed), named: installed.deletingPathExtension().lastPathComponent)
        } catch {
            NSSound.beep()
            mainView?.flash("CAN'T LOAD SKIN \(url.lastPathComponent)")
        }
    }

    @objc private func chooseSkin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            apply(DefaultSkin(), named: nil)
            return
        }
        do {
            apply(try WszSkin(url: url), named: url.deletingPathExtension().lastPathComponent)
        } catch {
            NSSound.beep()
            mainView?.flash("CAN'T LOAD SKIN \(url.lastPathComponent)")
        }
    }

    @objc private func installSkinFromPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installSkin(url)
    }

    @objc private func showSkinsFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SkinLibrary.folder)
    }

    /// Rebuilt each time it opens, so newly installed skins show up.
    private func rebuildSkinsMenu() {
        skinsMenu.removeAllItems()
        let current = preferences.skinName
        let standard = Menus.item("Bitamp Default", #selector(chooseSkin(_:)))
        standard.state = current == nil ? .on : .off
        skinsMenu.addItem(standard)
        let installed = SkinLibrary.installed()
        if !installed.isEmpty { skinsMenu.addItem(.separator()) }
        for url in installed {
            let name = url.deletingPathExtension().lastPathComponent
            let item = Menus.item(name, #selector(chooseSkin(_:)))
            item.representedObject = url
            item.state = name == current ? .on : .off
            skinsMenu.addItem(item)
        }
        skinsMenu.addItem(.separator())
        skinsMenu.addItem(Menus.item("Install Skin…", #selector(installSkinFromPanel(_:))))
        skinsMenu.addItem(Menus.item("Show Skins Folder", #selector(showSkinsFolder(_:))))
        for item in skinsMenu.items { item.target = self }
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        preferences.scale = sender.tag
        windowGroup?.setScale(CGFloat(sender.tag))
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
        let sizes = SkinnedView.scales.map { scale -> NSMenuItem in
            let item = Menus.item("\(scale)×", #selector(setScale(_:)), "\(scale)", [.command])
            item.tag = scale
            item.target = self
            return item
        }
        for item in [equalizer, playlist, minimize] { item.target = self }
        let windowMenu = Menus.menu("Window", [equalizer, playlist, .separator(), Menus.submenu(Menus.menu("Size", sizes)),
                                               .separator(), minimize])
        NSApp.windowsMenu = windowMenu

        skinsMenu.delegate = self

        return Menus.menu("", [appMenu, fileMenu, editMenu, Menus.playback(), Menus.visualization(), skinsMenu, windowMenu]
            .map(Menus.submenu))
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === skinsMenu { rebuildSkinsMenu() }
    }
}

extension AppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleEqualizer(_:)): item.state = windowGroup?.isVisible(.equalizer) == true ? .on : .off
        case #selector(togglePlaylist(_:)): item.state = windowGroup?.isVisible(.playlist) == true ? .on : .off
        case #selector(setScale(_:)): item.state = item.tag == preferences.scale ? .on : .off
        default: break
        }
        return true
    }
}
