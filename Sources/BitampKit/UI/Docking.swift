import AppKit

/// Geometry for snapping and docking windows, in screen coordinates (AppKit's, y up).
enum Docking {
    static let snapDistance: CGFloat = 10

    /// Where to put `frame` so that its edges line up with nearby edges of `others`
    /// or of `bounds` (the screen), when they're within `snapDistance`.
    static func snap(_ frame: CGRect, to others: [CGRect], within bounds: CGRect? = nil) -> CGPoint {
        var dx: CGFloat?
        var dy: CGFloat?
        func consider(_ distance: CGFloat, _ best: inout CGFloat?) {
            if abs(distance) <= snapDistance && abs(distance) < abs(best ?? .infinity) { best = distance }
        }
        for other in others {
            // Side-by-side snapping only matters when the windows are level with each other,
            // and stacking only when they're above or below each other.
            if frame.maxY + snapDistance >= other.minY && frame.minY - snapDistance <= other.maxY {
                consider(other.maxX - frame.minX, &dx)
                consider(other.minX - frame.maxX, &dx)
                consider(other.minX - frame.minX, &dx)
                consider(other.maxX - frame.maxX, &dx)
            }
            if frame.maxX + snapDistance >= other.minX && frame.minX - snapDistance <= other.maxX {
                consider(other.maxY - frame.minY, &dy)
                consider(other.minY - frame.maxY, &dy)
                consider(other.minY - frame.minY, &dy)
                consider(other.maxY - frame.maxY, &dy)
            }
        }
        if let bounds {
            consider(bounds.minX - frame.minX, &dx)
            consider(bounds.maxX - frame.maxX, &dx)
            consider(bounds.minY - frame.minY, &dy)
            consider(bounds.maxY - frame.maxY, &dy)
        }
        return CGPoint(x: frame.minX + (dx ?? 0), y: frame.minY + (dy ?? 0))
    }

    /// Whether two frames share part of an edge.
    static func touching(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        let overlapX = a.minX < b.maxX && b.minX < a.maxX
        let overlapY = a.minY < b.maxY && b.minY < a.maxY
        let stacked = overlapX && (abs(a.minY - b.maxY) <= tolerance || abs(a.maxY - b.minY) <= tolerance)
        let sideBySide = overlapY && (abs(a.minX - b.maxX) <= tolerance || abs(a.maxX - b.minX) <= tolerance)
        return stacked || sideBySide
    }

    /// Indexes of `others` docked to `anchor`, directly or through each other.
    static func docked(to anchor: CGRect, among others: [CGRect]) -> [Int] {
        var group = [anchor]
        var docked: [Int] = []
        var found = true
        while found {
            found = false
            for i in others.indices where !docked.contains(i) && group.contains(where: { touching($0, others[i]) }) {
                group.append(others[i])
                docked.append(i)
                found = true
            }
        }
        return docked.sorted()
    }
}

/// The main window plus the equalizer and playlist. Dragging the main window carries
/// whatever is docked to it; dragging another window moves it alone. Either way the
/// moved window snaps to the rest and to the screen edges.
@MainActor
final class WindowGroup {
    enum Panel: String, CaseIterable {
        case equalizer, playlist
    }

    let main: NSWindow
    private let panels: [Panel: NSWindow]
    private let defaults: UserDefaults
    private var drag: (lead: NSWindow, mouse: NSPoint, origins: [(NSWindow, NSPoint)])?

    init(main: NSWindow, panels: [Panel: NSWindow], defaults: UserDefaults = .standard) {
        self.main = main
        self.panels = panels
        self.defaults = defaults
        // All three windows show on first launch, like the classic layout.
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Panel.allCases.map { (Self.visibilityKey($0), true) }))
    }

    private var windows: [NSWindow] {
        [main] + Panel.allCases.compactMap { panels[$0] }
    }

    func isVisible(_ panel: Panel) -> Bool {
        panels[panel]?.isVisible ?? false
    }

    func setVisible(_ panel: Panel, _ visible: Bool) {
        guard let window = panels[panel] else { return }
        defaults.set(visible, forKey: Self.visibilityKey(panel))
        if visible {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    func toggle(_ panel: Panel) {
        setVisible(panel, !isVisible(panel))
    }

    /// Restores saved frames and visibility. Panels with no saved frame stack under the
    /// main window in the classic order: equalizer, then playlist.
    ///
    /// Frames saved at another size are rescaled around the main window's top-left corner,
    /// as `setScale` does, so the layout survives a size change between launches.
    func restore() {
        guard let mainView = main.contentView as? SkinnedView else { return }
        restoreShade()
        let savedMain = savedFrame(main)
        // The size the frames were saved at, from the main window's saved width.
        let savedScale = savedMain.map { $0.width / Layout.size.width } ?? mainView.scale
        let ratio = mainView.scale / savedScale
        if savedMain == nil { main.center() }
        let anchor = savedMain.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? NSPoint(x: main.frame.minX, y: main.frame.maxY)
        place(main, topLeft: anchor, pixelHeight: nil)

        var below = main.frame.minY
        for panel in Panel.allCases {
            guard let window = panels[panel] else { continue }
            if let saved = savedFrame(window) {
                place(window, topLeft: NSPoint(
                    x: anchor.x + (saved.minX - anchor.x) * ratio,
                    y: anchor.y + (saved.maxY - anchor.y) * ratio),
                      pixelHeight: saved.height / savedScale)
            } else {
                place(window, topLeft: NSPoint(x: main.frame.minX, y: below), pixelHeight: nil)
            }
            below = window.frame.minY
            if defaults.bool(forKey: Self.visibilityKey(panel)) { window.orderFront(nil) }
        }
        keepOnScreen()
    }

    /// Saves every window's frame; `restore` reads them back on the next launch.
    func saveLayout() {
        for window in windows {
            defaults.set(NSStringFromRect(window.frame), forKey: Self.key(window, "Frame"))
        }
    }

    private func savedFrame(_ window: NSWindow) -> NSRect? {
        if let string = defaults.string(forKey: Self.key(window, "Frame")) {
            let frame = NSRectFromString(string)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        // Earlier versions used AppKit's autosave: "x y width height …" under "NSWindow Frame Bitamp…".
        guard let legacy = defaults.string(forKey: "NSWindow Frame Bitamp\(Self.key(window, ""))") else { return nil }
        let numbers = legacy.split(separator: " ").prefix(4).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// A settings key for one window, such as "MainWindowFrame".
    private static func key(_ window: NSWindow, _ suffix: String) -> String {
        "\((window as? SkinnedWindow)?.layoutName ?? window.title)\(suffix)"
    }

    /// Sizes a window for its view's scale (and, for the playlist, a height in skin pixels)
    /// and puts its top-left corner at `topLeft`.
    private func place(_ window: NSWindow, topLeft: NSPoint, pixelHeight: CGFloat?) {
        guard let view = window.contentView as? SkinnedView else { return }
        let pixels = view.normalizedPixelSize(CGSize(
            width: view.pixelSize.width, height: (pixelHeight ?? view.pixelSize.height).rounded()))
        window.setContentSize(NSSize(width: pixels.width * view.scale, height: pixels.height * view.scale))
        window.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - window.frame.height))
    }

    /// Moves the main window and whatever is docked to it up, if needed, so the group's
    /// bottom edge clears the Dock. It never moves the top above the menu bar.
    private func keepOnScreen() {
        guard let screen = (main.screen ?? NSScreen.main)?.visibleFrame else { return }
        let visible = windows.filter { $0 !== main && $0.isVisible }
        let group = [main] + Docking.docked(to: main.frame, among: visible.map(\.frame)).map { visible[$0] }
        let bottom = group.map(\.frame.minY).min() ?? main.frame.minY
        let top = group.map(\.frame.maxY).max() ?? main.frame.maxY
        let lift = min(screen.minY - bottom, screen.maxY - top)
        guard lift > 0 else { return }
        for window in group {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: window.frame.minY + lift))
        }
    }

    private static func visibilityKey(_ panel: Panel) -> String {
        "\(panel.rawValue)Visible"
    }

    // MARK: - Shade mode

    func isShaded(_ window: NSWindow) -> Bool {
        (window.contentView as? SkinnedView)?.isShaded ?? false
    }

    func toggleShade(_ window: NSWindow) {
        setShaded(window, !isShaded(window))
    }

    func isShaded(_ panel: Panel) -> Bool {
        panels[panel].map(isShaded) ?? false
    }

    func toggleShade(_ panel: Panel) {
        if let window = panels[panel] { toggleShade(window) }
    }

    /// Collapses or expands a window from its top edge. Windows docked below it move with
    /// its bottom edge, so a docked stack stays docked.
    func setShaded(_ window: NSWindow, _ shaded: Bool) {
        guard let view = window.contentView as? SkinnedView, view.isShaded != shaded else { return }
        let others = windows.filter { $0 !== window && $0.isVisible }
        let below = Docking.docked(to: window.frame, among: others.map(\.frame))
            .map { others[$0] }
            .filter { $0.frame.maxY <= window.frame.minY + 1 }
        let top = window.frame.maxY
        let oldHeight = window.frame.height
        view.setShaded(shaded)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        let rise = oldHeight - window.frame.height
        for other in below {
            other.setFrameOrigin(NSPoint(x: other.frame.minX, y: other.frame.minY + rise))
        }
        defaults.set(shaded, forKey: Self.shadeKey(window))
        defaults.set(view.unshadedPixelHeight.map(Double.init), forKey: Self.unshadedHeightKey(window))
    }

    private static func shadeKey(_ window: NSWindow) -> String {
        key(window, "Shaded")
    }

    private static func unshadedHeightKey(_ window: NSWindow) -> String {
        key(window, "UnshadedHeight")
    }

    /// Puts windows back in shade mode before their frames are placed.
    private func restoreShade() {
        for window in windows where defaults.bool(forKey: Self.shadeKey(window)) {
            guard let view = window.contentView as? SkinnedView else { continue }
            let height = defaults.double(forKey: Self.unshadedHeightKey(window))
            view.setShaded(true)
            view.unshadedPixelHeight = height > 0 ? height : nil
        }
    }

    /// Resizes every window to `scale`, keeping the main window's top-left corner fixed
    /// and every other window at the same relative place, so docked windows stay docked.
    func setScale(_ scale: CGFloat) {
        guard let current = (main.contentView as? SkinnedView)?.scale, current != scale else { return }
        let ratio = scale / current
        let anchor = NSPoint(x: main.frame.minX, y: main.frame.maxY)
        for window in windows {
            guard let view = window.contentView as? SkinnedView else { continue }
            let offset = (x: window.frame.minX - anchor.x, y: window.frame.maxY - anchor.y)
            view.setScale(scale)
            window.setFrameOrigin(NSPoint(
                x: anchor.x + offset.x * ratio,
                y: anchor.y + offset.y * ratio - window.frame.height))
        }
        keepOnScreen()
    }

    // MARK: - Dragging

    func beginDrag(_ window: NSWindow) {
        var moving = [window]
        if window === main {
            let visible = windows.filter { $0 !== main && $0.isVisible }
            moving += Docking.docked(to: main.frame, among: visible.map(\.frame)).map { visible[$0] }
        }
        drag = (window, NSEvent.mouseLocation, moving.map { ($0, $0.frame.origin) })
    }

    func continueDrag() {
        guard let drag, let start = drag.origins.first?.1 else { return }
        let mouse = NSEvent.mouseLocation
        let proposed = CGRect(
            origin: CGPoint(x: start.x + mouse.x - drag.mouse.x, y: start.y + mouse.y - drag.mouse.y),
            size: drag.lead.frame.size)
        let stationary = windows.filter { window in
            window.isVisible && !drag.origins.contains { $0.0 === window }
        }
        let snapped = Docking.snap(proposed, to: stationary.map(\.frame), within: drag.lead.screen?.visibleFrame)
        let (dx, dy) = (snapped.x - start.x, snapped.y - start.y)
        for (window, origin) in drag.origins {
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }
    }

    func endDrag() {
        drag = nil
    }
}
