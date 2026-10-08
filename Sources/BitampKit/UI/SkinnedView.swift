import AppKit

/// Shared plumbing for Bitamp's windows: a 1× pixel canvas drawn at 2× with no
/// smoothing, hit-testing in skin pixels, a 30 fps redraw, and window dragging.
///
/// Subclasses draw in `render(into:)`, can add native-resolution drawing (such as
/// text) in `drawOverlay(in:)`, and handle the mouse in the `pixel…` methods.
class SkinnedView: NSView {
    static let framesPerSecond = 30.0
    static let scales: ClosedRange<Int> = 1...4

    var skin: Skin {
        didSet { skinDidChange() }
    }
    /// Points per skin pixel. 2 is the normal size; on a Retina display every value is crisp.
    private(set) var scale: CGFloat
    weak var windowGroup: WindowGroup?
    /// Shows a message in the main window's marquee, or nil to clear it.
    var announce: ((String?) -> Void)?
    /// Shows a message in the main window's marquee for a few seconds.
    var flashMessage: ((String) -> Void)?
    private(set) var canvas: Canvas
    private(set) var frameCount = 0
    private var timer: Timer?
    private var draggingWindow = false

    init(pixelSize: CGSize, skin: Skin, scale: CGFloat) {
        self.skin = skin
        self.scale = scale
        canvas = Canvas(pixelSize)
        super.init(frame: NSRect(origin: .zero, size: NSSize(
            width: pixelSize.width * scale, height: pixelSize.height * scale)))
    }

    /// Resizes the view, and its window, to draw at `scale` points per pixel.
    func setScale(_ scale: CGFloat) {
        let pixels = pixelSize
        self.scale = scale
        let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
        if let window {
            window.setContentSize(size)
        } else {
            setFrameSize(size)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { !isShapedWindow }

    /// Whether the art has transparent pixels around a shape, so the window takes that shape.
    var isShapedWindow: Bool { false }
    private var shadowIsStale = false

    /// Makes the window transparent around a shaped skin, or opaque again.
    func updateWindowShape() {
        guard let window else { return }
        window.isOpaque = !isShapedWindow
        window.backgroundColor = isShapedWindow ? .clear : .black
        shadowIsStale = true
        needsDisplay = true
    }

    /// Called after `skin` changes. Subclasses that change size with the skin resize here.
    func skinDidChange() {
        updateWindowShape()
        needsDisplay = true
    }

    /// Resizes the window to the size `normalizedPixelSize` asks for, such as after a skin
    /// change, keeping its top-left corner in place.
    func resizeKeepingTopLeft() {
        let pixels = normalizedPixelSize(pixelSize)
        let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
        guard let window else {
            setFrameSize(size)
            return
        }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var pixelSize: CGSize {
        CGSize(width: canvas.width, height: canvas.height)
    }

    /// Draw as the active window regardless of focus, for snapshots.
    var drawsAsActive = false

    var isActive: Bool {
        drawsAsActive || (window?.isKeyWindow ?? false)
    }

    /// Collapsed to a 14-pixel strip. Subclasses draw and hit-test differently while shaded.
    private(set) var isShaded = false
    /// The height to go back to when unshading.
    var unshadedPixelHeight: CGFloat?

    /// Collapses to or expands from the shade strip, keeping the width.
    func setShaded(_ shaded: Bool) {
        guard shaded != isShaded else { return }
        if shaded { unshadedPixelHeight = pixelSize.height }
        isShaded = shaded
        let height = shaded ? ShadeLayout.height : (unshadedPixelHeight ?? pixelSize.height)
        let pixels = normalizedPixelSize(CGSize(width: pixelSize.width, height: height))
        let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
        if let window {
            window.setContentSize(size)
        } else {
            setFrameSize(size)
        }
        updateWindowShape()
    }

    /// The nearest valid size for this window, in skin pixels. Fixed-size windows override
    /// this to return their size; the playlist snaps to its tile steps.
    func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        proposed
    }

    /// The size this view should be at its current scale.
    var naturalSize: NSSize {
        NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let pixels = normalizedPixelSize(CGSize(width: (newSize.width / scale).rounded(), height: (newSize.height / scale).rounded()))
        if pixels != pixelSize { canvas = Canvas(pixels) }
    }

    // MARK: - Frame loop

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        updateWindowShape()
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
        if isShapedWindow {
            // Start from clear pixels, so the window shows through around the shape.
            canvas.context.clear(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            context.clear(bounds)
        }
        render(into: canvas)
        context.interpolationQuality = .none
        context.draw(canvas.image(), in: bounds)
        drawOverlay(in: context)
        if shadowIsStale {
            // The shadow follows the window's pixels, so redo it once they're drawn.
            shadowIsStale = false
            DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
        }
    }

    /// A rect in skin pixels (top-left origin) as view coordinates.
    func viewRect(forPixels rect: CGRect) -> NSRect {
        NSRect(
            x: rect.minX * scale, y: bounds.height - rect.maxY * scale,
            width: rect.width * scale, height: rect.height * scale)
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
        return CGPoint(x: floor(point.x / scale), y: floor((bounds.height - point.y) / scale))
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
/// for menu commands while the equalizer or playlist has focus. A hidden window can't be
/// main, so the other windows also hand commands they don't handle to `actionFallback`.
final class SkinnedWindow: NSWindow {
    private let becomesMain: Bool
    /// Where commands this window's chain doesn't handle go: the main view.
    weak var actionFallback: NSResponder?
    /// Names this window's saved frame and shade state. `WindowGroup` saves and restores
    /// frames itself rather than with AppKit's autosave, which rewrites a saved frame as soon
    /// as the window moves, even mid-restore.
    let layoutName: String

    init(view: SkinnedView, layoutName: String, isMain: Bool) {
        becomesMain = isMain
        self.layoutName = layoutName
        super.init(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless, .miniaturizable],
            backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        // After the defaults: a shaped view makes the window clear when it moves in.
        contentView = view
        isReleasedWhenClosed = false
        title = "Bitamp"
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { becomesMain }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let actionFallback, actionFallback.responds(to: action) { return actionFallback }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// AppKit would nudge each window onto the screen by itself, which pulls docked
    /// windows apart. `WindowGroup` keeps the whole group on screen instead.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
