import AppKit
import BitampPakProtocol
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let builtInPaks: [Pak]
    private lazy var pakLibrary = PakLibrary()
    /// The built-in Paks, then the installed ones by name.
    private lazy var paks = PakRegistry(builtInPaks + pakLibrary.installed(), preferences: preferences)
    private var pakView: PakView?
    private var settingsPanels: [String: PakSettingsPanel] = [:]
    private lazy var controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: paks)
    /// "Add from…" panels, by Pak id, made when first opened.
    private var searchPanels: [String: PakSearchPanel] = [:]
    private var windowGroup: WindowGroup?
    private var mainView: MainView?
    private var views: [SkinnedView] = []
    private let skinsMenu = NSMenu(title: "Skins")
    /// Rebuilt as it opens, since its "Add from…" items follow the installed Paks.
    private let fileMenu = NSMenu(title: "File")

    /// `paks` are the Expansion Paks built into this copy of Bitamp.
    public init(paks: [Pak] = []) {
        builtInPaks = paks
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
        let equalizerView = EqualizerView(controller: controller, skin: skin, scale: preferences.scale)
        let playlistView = PlaylistView(controller: controller, preferences: preferences, skin: skin)
        playlistView.keyFallback = mainView
        let pakView = PakView(controller: controller, skin: skin, scale: preferences.scale)
        pakView.onSearch = { [weak self] pak in self?.showSearch(pak) }
        pakView.onSettings = { [weak self] pak in self?.showSettings(pak) }
        pakView.onInstall = { [weak self] url in self?.installPak(url) }
        pakView.onRemove = { [weak self] pak in self?.removePak(pak) }
        mainView.onPakDropped = { [weak self] url in self?.installPak(url) }
        self.pakView = pakView
        // An ejected Pak's search closes with it.
        pakView.onInsertedChange = { [weak self] pak, inserted in
            if !inserted { self?.searchPanels[pak.id]?.close() }
        }
        mainView.onShowPaks = { [weak self] in self?.windowGroup?.setVisible(.paks, true) }
        for view in [equalizerView, playlistView, pakView] as [SkinnedView] {
            view.announce = mainView.announce
            view.flashMessage = { [weak mainView] message in mainView?.flash(message, for: 2) }
        }

        let main = SkinnedWindow(view: mainView, layoutName: "MainWindow", isMain: true)
        let panels: [WindowGroup.Panel: SkinnedWindow] = [
            .equalizer: SkinnedWindow(view: equalizerView, layoutName: "EqualizerWindow", isMain: false),
            .playlist: SkinnedWindow(view: playlistView, layoutName: "PlaylistWindow", isMain: false),
            .paks: SkinnedWindow(view: pakView, layoutName: "PaksWindow", isMain: false),
        ]
        for window in panels.values { window.actionFallback = mainView }
        let group = WindowGroup(main: main, panels: panels)
        views = [mainView, equalizerView, playlistView, pakView]
        for view in views {
            view.windowGroup = group
        }
        group.setShadows(preferences.windowShadows)
        self.mainView = mainView
        windowGroup = group

        controller.restoreSession()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        windowGroup?.restore()
        windowGroup?.showAtLaunch()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller.saveSession()
        windowGroup?.saveLayout()
        for pak in paks.paks { (pak as? ExternalPak)?.disconnect() }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if let skin = urls.first(where: SkinLibrary.isSkin) {
            installSkin(skin)
        } else if let pak = urls.first(where: PakLibrary.isPak) {
            installPak(pak)
        } else {
            controller.open(urls)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the Dock icon brings back a hidden main window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowGroup?.setMainVisible(true)
        return false
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .folder] + ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.open(panel.urls)
    }

    // MARK: - Expansion Paks

    @objc private func chooseExpansionPak(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a .bitpak to install."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installPak(url)
    }

    /// Asks first, since a Pak is a program, then installs (or updates) it and shows it in
    /// the Expansion Paks window.
    private func installPak(_ url: URL) {
        let manifest: PakManifest
        do {
            guard PakLibrary.isPak(url) else { throw PakLibrary.InstallError.noManifest }
            manifest = try PakLibrary.manifest(in: url)
        } catch {
            showPakError("“\(url.lastPathComponent)” isn't an Expansion Pak Bitamp can install.", error)
            return
        }
        let existing = paks.paks.first { $0.id == manifest.id } as? ExternalPak
        let alert = NSAlert()
        alert.messageText = existing == nil
            ? "Install the “\(manifest.name)” Expansion Pak?"
            : "Replace the installed “\(existing!.name)” Pak with version \(manifest.version)?"
        alert.informativeText = [manifest.description,
            "A Pak is a program that runs on your Mac with your permissions. Only install Paks from people you trust."]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: existing == nil ? "Install" : "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            if let existing { unloadPak(existing) }
            try pakLibrary.install(url, reservedIDs: Set(builtInPaks.map(\.id)))
            guard let installed = pakLibrary.installed().first(where: { $0.id == manifest.id }) else { return }
            paks.register(installed)
            pakView?.paksChanged()
            windowGroup?.setVisible(.paks, true)
            mainView?.flash("\(installed.name) PAK INSTALLED", for: 2)
            if installed.hasSettings && installed.account == .disconnected { showSettings(installed) }
        } catch {
            showPakError("The “\(manifest.name)” Pak couldn't be installed.", error)
        }
    }

    private func removePak(_ pak: ExternalPak) {
        let alert = NSAlert()
        alert.messageText = "Remove the “\(pak.name)” Expansion Pak?"
        alert.informativeText = "Its songs stay in your playlist but won't play. Its settings are forgotten."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        unloadPak(pak)
        do {
            try pakLibrary.remove(pak)
        } catch {
            showPakError("The “\(pak.name)” Pak couldn't be removed.", error)
        }
        pakView?.paksChanged()
        mainView?.flash("\(pak.name) PAK REMOVED", for: 2)
    }

    /// Stops a third-party Pak and takes it out of Bitamp, before it's replaced or removed.
    private func unloadPak(_ pak: ExternalPak) {
        if controller.playingPak === pak { controller.stop() }
        pak.disconnect()
        searchPanels.removeValue(forKey: pak.id)?.close()
        settingsPanels.removeValue(forKey: pak.id)?.close()
        paks.unregister(pak)
    }

    private func showSettings(_ pak: ExternalPak) {
        let panel = settingsPanels[pak.id] ?? PakSettingsPanel(pak: pak)
        settingsPanels[pak.id] = panel
        panel.show()
    }

    private func showPakError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Skins

    private func savedSkin() -> Skin {
        if let theme = SkinTheme.builtIn(named: preferences.skinName) { return DefaultSkin(theme: theme) }
        guard let name = preferences.skinName, let url = SkinLibrary.url(named: name),
              let skin = try? WszSkin(url: url)
        else { return DefaultSkin() }
        return skin
    }

    private var currentSkinName: String {
        if let theme = SkinTheme.builtIn(named: preferences.skinName) { return theme.name }
        return preferences.skinName ?? SkinTheme.classic.name
    }

    private func apply(_ skin: Skin, named name: String?) {
        preferences.skinName = name
        for view in views { view.skin = skin }
        mainView?.flash("SKIN: \(currentSkinName)", for: 2)
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
        if let saved = sender.representedObject as? String, let theme = SkinTheme.builtIn(named: saved) {
            apply(DefaultSkin(theme: theme), named: theme.id == SkinTheme.classic.id ? nil : saved)
            return
        }
        guard let url = sender.representedObject as? URL else { return }
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

    /// Saves the current skin as a classic .wsz, for other players or for sharing.
    @objc private func exportSkin(_ sender: Any?) {
        guard let skin = views.first?.skin else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz")].compactMap { $0 }
        panel.nameFieldStringValue = "\(currentSkinName).wsz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WszWriter.write(skin, to: url)
            mainView?.flash("SKIN EXPORTED", for: 2)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func showSkinsFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: SkinLibrary.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SkinLibrary.folder)
    }

    /// Rebuilt each time it opens, so newly installed skins show up.
    private func rebuildSkinsMenu() {
        skinsMenu.removeAllItems()
        let current = preferences.skinName
        let currentBuiltIn = SkinTheme.builtIn(named: current)
        for theme in SkinTheme.builtIn {
            let item = Menus.item(theme.name, #selector(chooseSkin(_:)))
            item.representedObject = SkinTheme.builtInPrefix + theme.id
            item.state = currentBuiltIn?.id == theme.id ? .on : .off
            skinsMenu.addItem(item)
        }
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
        skinsMenu.addItem(Menus.item("Export Current Skin…", #selector(exportSkin(_:))))
        skinsMenu.addItem(Menus.item("Show Skins Folder", #selector(showSkinsFolder(_:))))
        for item in skinsMenu.items { item.target = self }
    }

    @objc private func toggleEqualizerShade(_ sender: Any?) {
        windowGroup?.toggleShade(.equalizer)
    }

    @objc private func togglePlaylistShade(_ sender: Any?) {
        windowGroup?.toggleShade(.playlist)
    }

    @objc private func toggleShadows(_ sender: Any?) {
        preferences.windowShadows.toggle()
        windowGroup?.setShadows(preferences.windowShadows)
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? CGFloat else { return }
        preferences.scale = scale
        windowGroup?.setScale(scale)
    }

    @objc private func minimize(_ sender: Any?) {
        windowGroup?.main.miniaturize(sender)
    }

    @objc private func toggleMainWindow(_ sender: Any?) {
        windowGroup?.toggleMain()
    }

    @objc private func regroupWindows(_ sender: Any?) {
        windowGroup?.regroup()
    }

    @objc private func toggleEqualizer(_ sender: Any?) {
        windowGroup?.toggle(.equalizer)
    }

    @objc private func togglePlaylist(_ sender: Any?) {
        windowGroup?.toggle(.playlist)
    }

    @objc func searchPak(_ sender: NSMenuItem) {
        if let pak = pak(for: sender) { showSearch(pak) }
    }

    /// The Pak a File menu item names, by id.
    private func pak(for item: NSMenuItem) -> Pak? {
        paks.paks.first { $0.id == item.representedObject as? String }
    }

    private func rebuildFileMenu() {
        let open = Menus.item("Open…", #selector(openDocument(_:)), "o", [.command])
        let addFromPaks = paks.paks.map { pak -> NSMenuItem in
            let item = Menus.item("Add from \(pak.name)…", #selector(searchPak(_:)))
            item.representedObject = pak.id
            return item
        }
        // The first Pak gets ⇧⌘A.
        if let first = addFromPaks.first {
            first.keyEquivalent = "a"
            first.keyEquivalentModifierMask = [.command, .shift]
        }
        let installPak = Menus.item("Install Expansion Pak…", #selector(chooseExpansionPak(_:)))
        fileMenu.removeAllItems()
        for item in [open, .separator()] + addFromPaks + [installPak] {
            if !item.isSeparatorItem { item.target = self }
            fileMenu.addItem(item)
        }
    }

    @objc private func togglePaks(_ sender: Any?) {
        windowGroup?.toggle(.paks)
    }

    private func showSearch(_ pak: Pak) {
        guard pak.isAvailable, paks.isInserted(pak) else { return }
        let panel = searchPanels[pak.id] ?? PakSearchPanel(pak: pak, controller: controller)
        searchPanels[pak.id] = panel
        panel.show()
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = Menus.menu("Bitamp", [
            Menus.item("About Bitamp", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            Menus.item("Hide Bitamp", #selector(NSApplication.hide(_:)), "h", [.command]),
            Menus.item("Quit Bitamp", #selector(NSApplication.terminate(_:)), "q", [.command]),
        ])

        rebuildFileMenu()
        fileMenu.delegate = self

        // Select All reaches the playlist when it has focus.
        let editMenu = Menus.menu("Edit", [
            Menus.item("Select All", #selector(NSResponder.selectAll(_:)), "a", [.command]),
        ])

        // The classic shortcuts: Alt+W for the main window, Alt+G for the equalizer and
        // Alt+E for the playlist.
        let mainWindow = Menus.item("Main Window", #selector(toggleMainWindow(_:)), "w", [.option])
        let equalizer = Menus.item("Equalizer", #selector(toggleEqualizer(_:)), "g", [.option])
        let playlist = Menus.item("Playlist", #selector(togglePlaylist(_:)), "e", [.option])
        let paksWindow = Menus.item("Expansion Paks", #selector(togglePaks(_:)), "k", [.option])
        let regroup = Menus.item("Regroup Windows", #selector(regroupWindows(_:)), "r", [.option])
        let minimize = Menus.item("Minimize", #selector(minimize(_:)), "m", [.command])
        let sizes = SkinnedView.scales.enumerated().map { index, scale -> NSMenuItem in
            let title = scale.rounded() == scale ? String(Int(scale)) : String(Double(scale))
            let item = Menus.item("\(title)×", #selector(setScale(_:)), "\(index + 1)", [.command])
            item.representedObject = scale
            item.target = self
            return item
        }
        // Shade mode: the main window's item goes to the main view, like the playback commands.
        let mainShade = Menus.item("Shade Main Window", #selector(MainView.toggleShade(_:)), "w", [.control])
        let equalizerShade = Menus.item("Shade Equalizer", #selector(toggleEqualizerShade(_:)), "w", [.control, .option])
        let playlistShade = Menus.item("Shade Playlist", #selector(togglePlaylistShade(_:)), "w", [.control, .shift])
        let shadows = Menus.item("Window Shadows", #selector(toggleShadows(_:)))
        for item in [mainWindow, equalizer, playlist, paksWindow, regroup, minimize, equalizerShade, playlistShade, shadows] { item.target = self }
        let windowMenu = Menus.menu("Window", [
            mainWindow, equalizer, playlist, paksWindow, regroup, .separator(),
            mainShade, equalizerShade, playlistShade, .separator(),
            Menus.submenu(Menus.menu("Size", sizes)), shadows, .separator(),
            minimize,
        ])
        NSApp.windowsMenu = windowMenu

        skinsMenu.delegate = self

        return Menus.menu("", [appMenu, fileMenu, editMenu, Menus.playback(), Menus.visualization(), skinsMenu, windowMenu]
            .map(Menus.submenu))
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === skinsMenu { rebuildSkinsMenu() }
        if menu === fileMenu { rebuildFileMenu() }
    }
}

extension AppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMainWindow(_:)):
            item.state = windowGroup?.isMainVisible == true ? .on : .off
            return windowGroup.map { !$0.isMainVisible || $0.canHideMain } ?? false
        case #selector(toggleEqualizer(_:)): item.state = windowGroup?.isVisible(.equalizer) == true ? .on : .off
        case #selector(togglePlaylist(_:)): item.state = windowGroup?.isVisible(.playlist) == true ? .on : .off
        case #selector(togglePaks(_:)): item.state = windowGroup?.isVisible(.paks) == true ? .on : .off
        case #selector(setScale(_:)): item.state = item.representedObject as? CGFloat == preferences.scale ? .on : .off
        case #selector(toggleShadows(_:)): item.state = preferences.windowShadows ? .on : .off
        case #selector(searchPak(_:)):
            guard let pak = pak(for: item) else { return false }
            return pak.isAvailable && paks.isInserted(pak)
        case #selector(toggleEqualizerShade(_:)):
            item.state = windowGroup.map { $0.isShaded(.equalizer) } == true ? .on : .off
            return windowGroup?.isVisible(.equalizer) == true
        case #selector(togglePlaylistShade(_:)):
            item.state = windowGroup.map { $0.isShaded(.playlist) } == true ? .on : .off
            return windowGroup?.isVisible(.playlist) == true
        default: break
        }
        return true
    }
}
