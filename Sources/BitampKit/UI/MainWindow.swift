import AppKit

/// A borderless window sized to the skin. It draws its own title bar, so it has to
/// opt back in to becoming key and main.
final class MainWindow: NSWindow {
    init(view: MainView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless, .miniaturizable],
            backing: .buffered, defer: false)
        contentView = view
        isOpaque = true
        hasShadow = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        title = "Bitamp"
        center()
        setFrameAutosaveName("BitampMainWindow")
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
