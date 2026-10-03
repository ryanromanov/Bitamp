import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = PlayerEngine()
    private var window: MainWindow?
    private var mainView: MainView?

    public override init() {
        super.init()
    }

    // The window is built before launch finishes, because Finder's "Open With"
    // delivers files before applicationDidFinishLaunching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let view = MainView(engine: engine, skin: DefaultSkin())
        view.onOpenFiles = { [weak self] urls in self?.open(urls) }
        view.onEject = { [weak self] in self?.openDocument(nil) }
        mainView = view
        window = MainWindow(view: view)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            try engine.load(url)
            engine.play()
        } catch {
            NSSound.beep()
            mainView?.flash("CAN'T OPEN \(url.lastPathComponent)")
        }
    }

    // MARK: - Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc private func previous(_ sender: Any?) { engine.restart() }
    @objc private func play(_ sender: Any?) {
        if engine.track == nil { openDocument(sender) } else { engine.play() }
    }
    @objc private func pause(_ sender: Any?) { engine.pause() }
    @objc private func stop(_ sender: Any?) { engine.stop() }
    @objc private func next(_ sender: Any?) { engine.restart() }
    @objc private func minimize(_ sender: Any?) { window?.miniaturize(sender) }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bitamp",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Bitamp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Bitamp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Bitamp", to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open…", #selector(openDocument(_:)), "o", [.command]))
        add(fileMenu, titled: "File", to: mainMenu)

        // Bare-letter shortcuts, as on the classic players.
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenu.addItem(item("Previous", #selector(previous(_:)), "z"))
        playbackMenu.addItem(item("Play", #selector(play(_:)), "x"))
        playbackMenu.addItem(item("Pause", #selector(pause(_:)), "c"))
        playbackMenu.addItem(item("Stop", #selector(stop(_:)), "v"))
        playbackMenu.addItem(item("Next", #selector(next(_:)), "b"))
        add(playbackMenu, titled: "Playback", to: mainMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(minimize(_:)), "m", [.command]))
        add(windowMenu, titled: "Window", to: mainMenu)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func item(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func add(_ menu: NSMenu, titled title: String, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }
}
