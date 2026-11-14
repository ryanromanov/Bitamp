import AppKit
import MetalKit

/// Where things sit in the Visualizer window, in skin pixels.
enum VisualizerLayout {
    static let defaultSize = CGSize(width: 275, height: 200)
    static let minSize = CGSize(width: 175, height: 120)
    /// The corner of the bottom edge that resizes the window.
    static let gripWidth: CGFloat = 20

    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(minSize.width, size.width.rounded()), height: max(minSize.height, size.height.rounded()))
    }

    /// Where the picture goes: inside the frame, leaving the playlist-style frame's right
    /// edge in view.
    static func picture(in size: CGSize, gen: Bool) -> CGRect {
        let content = PanelFrame.content(in: size, gen: gen)
        guard !gen else { return content }
        let track = PanelFrame.scrollTrack(in: size, gen: false)
        return CGRect(x: content.minX, y: content.minY, width: track.minX - content.minX, height: content.height)
    }

    static func grip(in size: CGSize, gen: Bool) -> CGRect {
        let bottom = CGFloat(gen ? GenArt.bottomHeight : PanelFrame.bottom)
        return CGRect(x: size.width - gripWidth, y: size.height - bottom, width: gripWidth, height: bottom)
    }
}

/// The full-window visualizer: a skinned frame around a Metal view that draws whichever
/// visual is chosen. It draws only while it's showing, and builds its Metal pieces the first
/// time that happens, so it costs nothing at launch or while hidden.
///
/// ← and → change the visual; F, Escape and a double-click toggle full screen, which moves
/// the Metal view into a window of its own, so the panel's size and place stay as they were.
final class VisualizerView: SkinnedView {
    private let controller: PlaybackController
    private let preferences: Preferences
    weak var keyFallback: NSResponder?
    private var metal: VisualizerMetalView?
    private var renderer: VisualizerRenderer?
    private var metalFailed = false
    private var fullScreen: FullScreenWindow?

    private enum Press: Equatable {
        case close, grip(startSize: CGSize, startMouse: NSPoint)
    }
    private var pressed: Press?
    private var pressedInside = false
    private var keyObservers: [NSObjectProtocol] = []

    private let title = "VISUALIZER"

    init(controller: PlaybackController, preferences: Preferences, skin: Skin, scale: CGFloat) {
        self.controller = controller
        self.preferences = preferences
        super.init(pixelSize: VisualizerLayout.defaultSize, skin: skin, scale: scale)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var accessibilityName: String { "Visualizer" }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        VisualizerLayout.clamped(proposed)
    }

    /// The frame only changes with focus; the Metal view animates itself.
    override var redrawsEveryFrame: Bool { false }

    var isFullScreen: Bool { fullScreen != nil }

    private var picture: CGRect { VisualizerLayout.picture(in: pixelSize, gen: skin.gen != nil) }

    override func layout() {
        super.layout()
        metal?.frame = viewRect(forPixels: picture)
    }

    override func skinDidChange() {
        super.skinDidChange()
        renderer?.setPalette(skin.visColors)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: nil, using: redraw)
        }
    }

    // MARK: - Frame loop

    /// Whether anyone can see the picture: the panel on screen, or full screen.
    private var isShowing: Bool {
        if fullScreen != nil { return true }
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    override func tick() {
        let showing = isShowing
        // Apple Music's sound is only reachable while something is listening for it.
        controller.visualizerWindowOpen = showing
        if showing { ensureMetal() }
        metal?.isPaused = !showing
        // One picture pixel to a skin pixel, so it matches the player, in full screen too: the
        // same fine pixels, not the same number of rows, which made them huge. A very big screen
        // takes bigger ones, so there are never more than about 540 rows to draw.
        let skinPixel = max(1, Int((scale * (window?.backingScaleFactor ?? 2)).rounded()))
        if fullScreen != nil, let metal {
            renderer?.pixelDivisor = max(skinPixel, Int((metal.drawableSize.height / 540).rounded(.up)))
        } else {
            renderer?.pixelDivisor = skinPixel
        }
        if showing, let renderer, let chosen = FullVisual(rawValue: preferences.fullVisual), chosen != renderer.visual {
            renderer.select(chosen)
        }
    }

    private func ensureMetal() {
        guard metal == nil, !metalFailed else { return }
        let view = VisualizerMetalView(frame: viewRect(forPixels: picture))
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        guard let renderer = VisualizerRenderer(view: view, analyzer: controller.engine.analyzer) else {
            metalFailed = true
            flashMessage?("THE VISUALIZER NEEDS METAL")
            return
        }
        renderer.setPalette(skin.visColors)
        if let chosen = FullVisual(rawValue: preferences.fullVisual) { renderer.select(chosen) }
        view.onFullScreen = { [weak self] in self?.toggleFullScreen() }
        self.renderer = renderer
        metal = view
        addSubview(view)
    }

    // MARK: - Visuals

    /// Moves to the next or previous visual and says which.
    func step(_ direction: Int) {
        let all = FullVisual.allCases
        let current = all.firstIndex(of: FullVisual(rawValue: preferences.fullVisual) ?? .barsAndWaves) ?? 0
        let next = all[(current + direction + all.count) % all.count]
        preferences.fullVisual = next.rawValue
        flashMessage?("VISUALIZER: \(next.title.uppercased())")
        announce?(nil)
        needsDisplay = true
    }

    // MARK: - Full screen

    func toggleFullScreen() {
        if fullScreen != nil {
            leaveFullScreen()
            return
        }
        guard let metal, let screen = window?.screen ?? NSScreen.main else { return }
        let screenWindow = FullScreenWindow(screen: screen)
        screenWindow.onKey = { [weak self] event in self?.fullScreenKey(event) }
        metal.removeFromSuperview()
        metal.frame = screenWindow.contentView?.bounds ?? screen.frame
        metal.autoresizingMask = [.width, .height]
        screenWindow.contentView?.addSubview(metal)
        fullScreen = screenWindow
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        screenWindow.makeKeyAndOrderFront(nil)
    }

    private func leaveFullScreen() {
        guard let screenWindow = fullScreen else { return }
        NSApp.presentationOptions = []
        fullScreen = nil
        if let metal {
            metal.removeFromSuperview()
            metal.autoresizingMask = []
            addSubview(metal)
            needsLayout = true
        }
        screenWindow.orderOut(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func fullScreenKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: leaveFullScreen()  // Escape
        case 123: step(-1)
        case 124: step(1)
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                leaveFullScreen()
            } else {
                keyFallback?.keyDown(with: event)
            }
        }
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive)
            .draw(c, closePressed: pressed == .close && pressedInside)
        c.fill(picture, .black)
    }

    // MARK: - Accessibility

    override func accessibleControls() -> [AccessibleControl] {
        let visual = FullVisual(rawValue: preferences.fullVisual) ?? .barsAndWaves
        return [
            AccessibleControl(id: "close", kind: .button, label: "Close",
                              rect: PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive).close,
                              press: { [weak self] in self?.windowGroup?.setVisible(.visualizer, false) }),
            AccessibleControl(id: "visual", kind: .text, label: "Visual: \(visual.title). Left and right arrows change it.", rect: picture),
        ]
    }

    // MARK: - Mouse and keys

    private func press(at point: CGPoint) -> Press? {
        if PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive).close.contains(point) { return .close }
        if VisualizerLayout.grip(in: pixelSize, gen: skin.gen != nil).contains(point) { return .grip(startSize: .zero, startMouse: .zero) }
        return nil
    }

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        window?.makeFirstResponder(self)
        guard let press = press(at: point) else { return false }
        switch press {
        case .grip:
            pressed = .grip(startSize: window?.frame.size ?? frame.size, startMouse: NSEvent.mouseLocation)
        case .close:
            pressed = .close
            pressedInside = true
        }
        return true
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        switch pressed {
        case .grip(let startSize, let startMouse)?:
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            let proposed = CGSize(width: (startSize.width + mouse.x - startMouse.x) / scale,
                                  height: (startSize.height - (mouse.y - startMouse.y)) / scale)
            let pixels = normalizedPixelSize(proposed)
            let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
            guard size != window.frame.size else { return }
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height),
                            display: true)
        case .close?:
            pressedInside = press(at: point) == .close
        case nil:
            break
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            pressed = nil
            pressedInside = false
            needsDisplay = true
        }
        if pressed == .close, pressedInside { windowGroup?.setVisible(.visualizer, false) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step(-1)
        case 124: step(1)
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                toggleFullScreen()
            } else if let keyFallback {
                keyFallback.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// The Metal view. A double-click goes full screen; any other click is the window's, so
/// dragging the picture moves the panel.
final class VisualizerMetalView: MTKView {
    var onFullScreen: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onFullScreen?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// A borderless window over the whole screen that holds the picture in full screen. It
/// passes keys to the visualizer.
final class FullScreenWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .mainMenu + 1
        backgroundColor = .black
        isReleasedWhenClosed = false
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }
}
