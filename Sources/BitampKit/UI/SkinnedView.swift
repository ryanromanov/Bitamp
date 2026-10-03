import AppKit

/// Shared plumbing for Bitamp's windows: a 1× pixel canvas drawn at 2× with no
/// smoothing, hit-testing in skin pixels, a 30 fps redraw, and window dragging.
///
/// Subclasses draw in `render(into:)`, can add native-resolution drawing (such as
/// text) in `drawOverlay(in:)`, and handle the mouse in the `pixel…` methods.
class SkinnedView: NSView {
    static let scale: CGFloat = 2
    static let framesPerSecond = 30.0

    var skin: Skin
    weak var windowGroup: WindowGroup?
    /// Shows a message in the main window's marquee, or nil to clear it.
    var announce: ((String?) -> Void)?
    private(set) var canvas: Canvas
    private(set) var frameCount = 0
    private var timer: Timer?
    private var draggingWindow = false

    init(pixelSize: CGSize, skin: Skin) {
        self.skin = skin
        canvas = Canvas(pixelSize)
        super.init(frame: NSRect(origin: .zero, size: NSSize(
            width: pixelSize.width * Self.scale, height: pixelSize.height * Self.scale)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var pixelSize: CGSize {
        CGSize(width: canvas.width, height: canvas.height)
    }

    var isActive: Bool {
        window?.isKeyWindow ?? false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let pixels = CGSize(width: (newSize.width / Self.scale).rounded(), height: (newSize.height / Self.scale).rounded())
        if pixels != pixelSize { canvas = Canvas(pixels) }
    }

    // MARK: - Frame loop

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func frameTick() {
        frameCount += 1
        tick()
        if window?.isVisible == true { needsDisplay = true }
    }

    /// Called every frame before redrawing.
    func tick() {}

    // MARK: - Drawing

    func render(into canvas: Canvas) {}

    func drawOverlay(in context: CGContext) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        render(into: canvas)
        context.interpolationQuality = .none
        context.draw(canvas.image(), in: bounds)
        drawOverlay(in: context)
    }

    /// A rect in skin pixels (top-left origin) as view coordinates.
    func viewRect(forPixels rect: CGRect) -> NSRect {
        NSRect(
            x: rect.minX * Self.scale, y: bounds.height - rect.maxY * Self.scale,
            width: rect.width * Self.scale, height: rect.height * Self.scale)
    }

    /// Draws `text` in the pixel font, clipped to the canvas.
    func drawPixelText(_ c: Canvas, _ text: String, _ x: Int, _ y: Int) {
        for (index, character) in PixelFont.normalize(text).enumerated() {
            let glyphX = x + index * PixelFont.cellWidth
            guard glyphX < c.width else { break }
            if glyphX > -PixelFont.cellWidth {
                c.draw(skin.glyph(for: character), glyphX, y)
            }
        }
    }

    // MARK: - Mouse

    func pixel(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: floor(point.x / Self.scale), y: floor((bounds.height - point.y) / Self.scale))
    }

    /// Return false to start dragging the window instead.
    func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool { false }
    func pixelMouseDragged(to point: CGPoint, event: NSEvent) {}
    func pixelMouseUp(at point: CGPoint, event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        if !pixelMouseDown(at: pixel(for: event), event: event) {
            draggingWindow = true
            if let window, let windowGroup {
                windowGroup.beginDrag(window)
            } else {
                window?.performDrag(with: event)
                draggingWindow = false
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingWindow {
            windowGroup?.continueDrag()
        } else {
            pixelMouseDragged(to: pixel(for: event), event: event)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingWindow {
            windowGroup?.endDrag()
            draggingWindow = false
        } else {
            pixelMouseUp(at: pixel(for: event), event: event)
        }
        needsDisplay = true
    }
}

/// Bitamp's windows draw their own frames, so they're borderless but can still become key.
/// Only the main window becomes main, which keeps the main view in the responder chain
/// for menu commands while the equalizer or playlist has focus.
final class SkinnedWindow: NSWindow {
    private let becomesMain: Bool

    init(view: SkinnedView, autosaveName: String, isMain: Bool) {
        becomesMain = isMain
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
        setFrameAutosaveName(autosaveName)
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { becomesMain }

    /// AppKit would nudge each window onto the screen by itself, which pulls docked
    /// windows apart. `WindowGroup` keeps the whole group on screen instead.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
