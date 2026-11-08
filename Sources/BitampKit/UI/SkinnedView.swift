import AppKit

/// Shared plumbing for Bitamp's windows: a 1× pixel canvas drawn at 2× with no
/// smoothing, hit-testing in skin pixels, a 30 fps redraw, and window dragging.
///
/// Subclasses draw in `render(into:)`, can add native-resolution drawing (such as
/// text) in `drawOverlay(in:)`, and handle the mouse in the `pixel…` methods.
class SkinnedView: NSView {
    static let framesPerSecond = 30.0
    /// The window sizes, in points per skin pixel. 2 is the default. On a Retina display
    /// each is a whole number of screen pixels per skin pixel (2, 3 and 4), so all stay sharp.
    static let scales: [CGFloat] = [1, 1.5, 2]

    /// The size in `scales` closest to `scale`, for sizes saved by older versions (3× and 4×)
    /// or worked out from a window's width.
    static func nearestScale(to scale: CGFloat) -> CGFloat {
        scales.min { abs($0 - scale) < abs($1 - scale) }!
    }

    var skin: Skin {
        didSet { skinDidChange() }
    }
    /// Points per skin pixel, one of `scales`. 2 is the normal size.
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
        if !accessibilityName.isEmpty { window?.setAccessibilityTitle(accessibilityName) }
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
        if window?.isVisible == true && redrawsEveryFrame { needsDisplay = true }
    }

    /// Called every frame before redrawing.
    func tick() {}

    /// Whether to redraw every frame. A window whose pictures only change when something
    /// happens returns false while nothing moves, and sets `needsDisplay` when it changes;
    /// clicks, drags and key presses redraw it anyway.
    var redrawsEveryFrame: Bool { true }

    // MARK: - Accessibility

    /// What VoiceOver calls this window, such as "Equalizer".
    var accessibilityName: String { "" }

    /// The window's controls for VoiceOver, in any order: VoiceOver gets them in reading
    /// order, row by row (`readingOrder`). Windows override this; it's
    /// asked often, so it should be quick, and it should follow what's drawn now (shade
    /// mode, the skin's shape).
    func accessibleControls() -> [AccessibleControl] { [] }

    private var accessibilityElements: [AnyHashable: SkinnedAccessibilityElement] = [:]
    private var accessibilityOrder: [AnyHashable] = []

    /// The control with `id`, at the top or inside a list.
    func accessibleControl(_ id: AnyHashable) -> AccessibleControl? {
        func find(_ controls: [AccessibleControl]) -> AccessibleControl? {
            for control in controls {
                if control.id == id { return control }
                if let found = find(control.children) { return found }
            }
            return nil
        }
        return find(accessibleControls())
    }

    /// The control the window's keyboard is on, such as a playlist row, which VoiceOver
    /// follows. Windows with a keyboard focus of their own override this.
    var accessibilityFocusedID: AnyHashable? { nil }

    /// The view itself isn't one; its controls stand in its place, beside any real subviews
    /// (a text box's field).
    override func isAccessibilityElement() -> Bool { false }

    /// `controls` in the order they're seen: rows from the top, each from the left. A
    /// control joins a row when its middle is within a few pixels of the row's first. A
    /// list's own children keep their order.
    static func readingOrder(_ controls: [AccessibleControl]) -> [AccessibleControl] {
        var rows: [(midY: CGFloat, controls: [AccessibleControl])] = []
        for control in controls.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last, control.rect.midY - last.midY <= 6 {
                rows[rows.count - 1].controls.append(control)
            } else {
                rows.append((control.rect.midY, [control]))
            }
        }
        return rows.flatMap { $0.controls.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// Makes sure every control, inside lists too, has its element, and returns the top
    /// level's in reading order. Elements stay while their controls do.
    @discardableResult
    func syncAccessibilityElements() -> [SkinnedAccessibilityElement] {
        let controls = Self.readingOrder(accessibleControls())
        var seen: [AnyHashable] = []
        func sync(_ controls: [AccessibleControl], parent: Any) -> [SkinnedAccessibilityElement] {
            controls.map { control in
                seen.append(control.id)
                // A control that became another kind needs another element.
                let element: SkinnedAccessibilityElement
                if let existing = accessibilityElements[control.id], type(of: existing) == control.elementClass {
                    element = existing
                } else {
                    element = control.elementClass.init(owner: self, id: control.id)
                    accessibilityElements[control.id] = element
                }
                element.setAccessibilityParent(parent)
                element.childElements = sync(control.children, parent: element)
                return element
            }
        }
        let top = sync(controls, parent: self)
        if seen != accessibilityOrder {
            accessibilityElements = accessibilityElements.filter { seen.contains($0.key) }
            let changed = !accessibilityOrder.isEmpty
            accessibilityOrder = seen
            if changed {
                // After this answer, so VoiceOver asks again.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    NSAccessibility.post(element: self, notification: .layoutChanged)
                }
            }
        }
        return top
    }

    override func accessibilityChildren() -> [Any]? {
        // A text field says it isn't an element (its cell is), so it's given as it is.
        let fields = subviews.filter { !$0.isHidden }
        return syncAccessibilityElements() + fields
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return super.accessibilityHitTest(point) }
        let inView = convert(window.convertPoint(fromScreen: point), from: nil)
        let pixel = CGPoint(x: inView.x / scale, y: (bounds.height - inView.y) / scale)
        // The innermost control there: a row before its list.
        func hit(_ controls: [AccessibleControl]) -> AccessibleControl? {
            guard let control = controls.last(where: { $0.rect.contains(pixel) }) else { return nil }
            return hit(control.children) ?? control
        }
        if let control = hit(accessibleControls()) {
            syncAccessibilityElements()
            return accessibilityElements[control.id]
        }
        return super.accessibilityHitTest(point)
    }

    override var accessibilityFocusedUIElement: Any? {
        guard let id = accessibilityFocusedID else { return super.accessibilityFocusedUIElement }
        syncAccessibilityElements()
        return accessibilityElements[id] ?? super.accessibilityFocusedUIElement
    }

    /// Tells VoiceOver the keyboard moved, to `accessibilityFocusedID`, and that its list's
    /// selection may have changed, so it says where it is.
    func accessibilityFocusMoved() {
        syncAccessibilityElements()
        guard let id = accessibilityFocusedID, let element = accessibilityElements[id] else { return }
        if let list = element.accessibilityParent() as? SkinnedAccessibilityElement {
            NSAccessibility.post(element: list, notification: .selectedChildrenChanged)
        }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
    }

    /// Tells VoiceOver a control's value changed by itself, such as a new song.
    func announceValueChange(_ id: AnyHashable) {
        guard let element = accessibilityElements[id] else { return }
        NSAccessibility.post(element: element, notification: .valueChanged)
    }

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
        drawCanvas(canvas.image(), in: context)
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

    /// Draws the canvas at exactly `scale` points per pixel from the top-left corner.
    /// AppKit sizes windows in whole points, so at 1.5× an odd number of pixels leaves half
    /// a point over on the right or bottom. Stretching the art across it would make one
    /// pixel wider than the rest, so the art keeps its exact size and the edge pixels fill
    /// the strip.
    private func drawCanvas(_ image: CGImage, in context: CGContext) {
        let art = CGRect(x: 0, y: bounds.height - CGFloat(canvas.height) * scale,
                         width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
        context.draw(image, in: art)
        let right = bounds.width - art.maxX, below = art.minY
        guard right > 0 || below > 0 else { return }
        // Image coordinates run from the top-left; drawing coordinates from the bottom-left.
        func fill(_ pixels: CGRect, _ rect: CGRect) {
            guard rect.width > 0, rect.height > 0, let piece = image.cropping(to: pixels) else { return }
            context.draw(piece, in: rect)
        }
        let lastX = CGFloat(canvas.width - 1), lastY = CGFloat(canvas.height - 1)
        fill(CGRect(x: lastX, y: 0, width: 1, height: CGFloat(canvas.height)),
             CGRect(x: art.maxX, y: art.minY, width: right, height: art.height))
        fill(CGRect(x: 0, y: lastY, width: CGFloat(canvas.width), height: 1),
             CGRect(x: 0, y: 0, width: art.width, height: below))
        fill(CGRect(x: lastX, y: lastY, width: 1, height: 1),
             CGRect(x: art.maxX, y: 0, width: right, height: below))
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
