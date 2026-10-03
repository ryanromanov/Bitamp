import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
    private var window: MainWindow?
    private var mainView: MainView?

    public override init() {
        super.init()
    }

    // The window is built before launch finishes, because Finder's "Open With"
    // delivers files before applicationDidFinishLaunching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        view.onOpen = { [weak self] in self?.openDocument(nil) }
        controller.onError = { [weak view] message in
            NSSound.beep()
            view?.flash(message)
        }
        mainView = view
        window = MainWindow(view: view)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        controller.open(urls)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.open(panel.urls)
    }

    @objc private func minimize(_ sender: Any?) {
        window?.miniaturize(sender)
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

        let minimize = Menus.item("Minimize", #selector(minimize(_:)), "m", [.command])
        minimize.target = self
        let windowMenu = Menus.menu("Window", [minimize])
        NSApp.windowsMenu = windowMenu

        return Menus.menu("", [appMenu, fileMenu, Menus.playback(), Menus.visualization(), windowMenu].map(Menus.submenu))
    }
}
