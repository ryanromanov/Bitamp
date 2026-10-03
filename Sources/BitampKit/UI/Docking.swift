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
    func restore() {
        var below = main.frame.minY
        for panel in Panel.allCases {
            guard let window = panels[panel] else { continue }
            if !window.setFrameUsingName(window.frameAutosaveName) {
                window.setFrameOrigin(NSPoint(x: main.frame.minX, y: below - window.frame.height))
            }
            below = window.frame.minY
            if defaults.bool(forKey: Self.visibilityKey(panel)) { window.orderFront(nil) }
        }
        keepOnScreen()
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
