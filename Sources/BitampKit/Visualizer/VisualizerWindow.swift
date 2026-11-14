import AppKit
import MetalKit

/// The full-window visualizer. ← → change visuals; F or a double-click goes full screen.
/// A plain resizable window for now; the skinned frame comes after the visuals settle.
@MainActor
final class VisualizerWindowController: NSWindowController, NSWindowDelegate {
    private let renderer: VisualizerRenderer
    private let view: VisualizerView

    init?(analyzer: SpectrumAnalyzer) {
        let view = VisualizerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 60
        guard let renderer = VisualizerRenderer(view: view, analyzer: analyzer) else { return nil }
        self.renderer = renderer
        self.view = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 10)
        window.setFrameAutosaveName("VisualizerWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        view.onStep = { [weak self] step in self?.renderer.select((self?.renderer.index ?? 0) + step) }
        view.onFullScreen = { [weak window] in window?.toggleFullScreen(nil) }
        renderer.onChange = { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    private func updateTitle() {
        window?.title = "Bitamp Visualizer - \(renderer.name)"
    }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) } else { showWindow(nil) }
    }

    var isVisible: Bool { window?.isVisible == true }
}

final class VisualizerView: MTKView {
    var onStep: ((Int) -> Void)?
    var onFullScreen: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onFullScreen?() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep?(-1)  // left
        case 124: onStep?(1)   // right
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { onFullScreen?() } else { super.keyDown(with: event) }
        }
    }
}
