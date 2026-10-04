import CoreGraphics

/// Geometry of the Orb main window in 1× pixels, origin top-left: a big round play button
/// in a brushed ring, joined to a rounded body that holds the display. Everything outside
/// the shape is transparent, so the window takes the shape of the art.
enum OrbLayout {
    static let size = CGSize(width: 318, height: 116)

    static let orbCenter = CGPoint(x: 58, y: 58)
    static let orbRadius: CGFloat = 58
    static let playRadius: CGFloat = 30
    /// The ring the smaller transport buttons sit on, and their size.
    static let ringRadius: CGFloat = 44.5
    static let buttonRadius: CGFloat = 8

    static let body = CGRect(x: 52, y: 20, width: 266, height: 76)
    static let titleTab = CGRect(x: 148, y: 4, width: 150, height: 22)
    static let footTab = CGRect(x: 154, y: 90, width: 112, height: 22)
    /// Where the window can be grabbed and double-clicked for shade mode.
    static let titleBar = CGRect(x: 148, y: 4, width: 150, height: 16)
    static let titleText = CGPoint(x: 168, y: 9)

    static let display = CGRect(x: 124, y: 30, width: 140, height: 52)
    static let playStatus = CGPoint(x: 128, y: 36)
    static let minus = CGPoint(x: 138, y: 34)
    static let timeDigits: [CGPoint] = [150, 162, 180, 192].map { CGPoint(x: $0, y: 34) }
    static let timeColon = CGPoint(x: 174, y: 37)
    static let timeDisplay = CGRect(x: 126, y: 32, width: 78, height: 17)
    static let info = CGPoint(x: 210, y: 33)
    static let infoLineHeight = 7
    static let marquee = CGRect(x: 128, y: 55, width: 132, height: 6)
    static let visualizer = CGRect(x: 128, y: 64, width: 132, height: 16)

    static let position = CGRect(x: 124, y: 84, width: 140, height: 9)
    static let positionThumb = CGSize(width: 12, height: 7)
    static let positionGroove = CGRect(x: 124, y: 87, width: 140, height: 3)
    static let volume = CGRect(x: 279, y: 32, width: 14, height: 52)
    static let volumeThumb = CGSize(width: 14, height: 8)
    static let volumeGroove = CGRect(x: 284, y: 34, width: 3, height: 48)
    static let speaker = CGPoint(x: 297, y: 55)

    static func titleButton(_ button: TitleButton) -> CGRect {
        switch button {
        case .options: return CGRect(x: 154, y: 7, width: 10, height: 10)
        case .minimize: return CGRect(x: 258, y: 7, width: 10, height: 10)
        case .shade: return CGRect(x: 270, y: 7, width: 10, height: 10)
        case .close: return CGRect(x: 282, y: 7, width: 10, height: 10)
        }
    }

    /// The center of a transport button; play is the orb itself.
    static func center(of button: TransportButton) -> CGPoint {
        let angle: Double
        switch button {
        case .play: return orbCenter
        case .eject: angle = 150
        case .previous: angle = 200
        case .pause: angle = 240
        case .stop: angle = 300
        case .next: angle = 340
        }
        let radians = angle * .pi / 180
        return CGPoint(x: orbCenter.x + ringRadius * cos(radians), y: orbCenter.y - ringRadius * sin(radians))
    }

    static func radius(of button: TransportButton) -> CGFloat {
        button == .play ? playRadius : buttonRadius
    }

    /// The square a transport button's sprite fills, with a pixel for its dark rim.
    static func rect(of button: TransportButton) -> CGRect {
        let center = center(of: button), r = radius(of: button) + 1
        return CGRect(x: (center.x - r).rounded(), y: (center.y - r).rounded(), width: r * 2, height: r * 2)
    }

    /// The toggles, as pills in the tab under the body.
    static let toggles: [ToggleButton] = [.equalizer, .playlist, .shuffle, .repeatTrack]

    static func label(of button: ToggleButton) -> String {
        switch button {
        case .equalizer: return "EQ"
        case .playlist: return "PL"
        case .shuffle: return "SHUF"
        case .repeatTrack: return "REP"
        }
    }

    static func rect(of button: ToggleButton) -> CGRect {
        var x: CGFloat = 162
        for toggle in toggles {
            let width = CGFloat(PixelFont.width(of: label(of: toggle)) + 9)
            if toggle == button { return CGRect(x: x, y: 98, width: width, height: 10) }
            x += width + 2
        }
        return .zero
    }

    /// Whether `point` is on the window's shape, rather than a transparent pixel.
    static func contains(_ point: CGPoint) -> Bool {
        OrbShape.circle(orbCenter, orbRadius)(Int(point.x), Int(point.y))
            || OrbShape.roundRect(body, 38)(Int(point.x), Int(point.y))
            || OrbShape.roundRect(titleTab, 9)(Int(point.x), Int(point.y))
            || OrbShape.roundRect(footTab, 9)(Int(point.x), Int(point.y))
    }

    /// The control under `point`. Round buttons are hit-tested as circles.
    static func control(at point: CGPoint) -> Control? {
        for button in TitleButton.allCases where titleButton(button).contains(point) { return .title(button) }
        for button in TransportButton.allCases {
            let center = center(of: button), r = radius(of: button) + 1
            let (dx, dy) = (point.x + 0.5 - center.x, point.y + 0.5 - center.y)
            if dx * dx + dy * dy <= r * r { return .transport(button) }
        }
        for button in toggles where rect(of: button).contains(point) { return .toggle(button) }
        if volume.contains(point) { return .volume }
        if position.contains(point) { return .position }
        if timeDisplay.contains(point) { return .timeDisplay }
        if visualizer.contains(point) { return .visualizer }
        return nil
    }

    static func rect(of control: Control) -> CGRect {
        switch control {
        case .title(let button): return titleButton(button)
        case .transport(let button): return rect(of: button)
        case .toggle(let button): return rect(of: button)
        case .volume: return volume
        case .position: return position
        case .timeDisplay: return timeDisplay
        case .visualizer: return visualizer
        case .about, .balance: return .zero
        }
    }
}

/// Pixel shapes for the Orb: each says whether a pixel, by its top-left corner, is inside.
enum OrbShape {
    typealias Test = (Int, Int) -> Bool

    static func circle(_ center: CGPoint, _ r: CGFloat) -> Test {
        { x, y in
            let (dx, dy) = (CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y)
            return dx * dx + dy * dy <= r * r
        }
    }

    static func roundRect(_ rect: CGRect, _ r: CGFloat) -> Test {
        { x, y in
            let (px, py) = (CGFloat(x) + 0.5, CGFloat(y) + 0.5)
            guard rect.contains(CGPoint(x: px, y: py)) else { return false }
            let cx = min(max(px, rect.minX + r), rect.maxX - r)
            let cy = min(max(py, rect.minY + r), rect.maxY - r)
            return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r
        }
    }
}

/// Draws the Orb's sprites from a theme. `MainView` composes them using `OrbLayout`.
final class OrbArt {
    let theme: SkinTheme
    private var cache: [String: CGImage] = [:]

    init(theme: SkinTheme) {
        self.theme = theme
    }

    private var white: CGColor { rgb(0xffffff) }
    private var outline: CGColor { theme.groove }

    private var gel: (top: CGColor, bottom: CGColor, pressedTop: CGColor, pressedBottom: CGColor, edge: CGColor) {
        if case .gel(let top, let bottom, let pressedTop, let pressedBottom, let edge) = theme.buttonStyle {
            return (top, bottom, pressedTop, pressedBottom, edge)
        }
        return (theme.faceLight, theme.faceButton, theme.facePressed, theme.faceButton, theme.faceDark)
    }

    private var metal: (top: CGColor, bottom: CGColor) {
        if case .brushed(let top, let bottom) = theme.panel { return (top, bottom) }
        return (theme.faceLight, theme.face)
    }

    /// The filled part of the seek and volume tracks, with a brighter shine on one edge.
    var fill: CGColor { theme.levelMid }
    var fillShine: CGColor { theme.levelHigh }

    private func cached(_ key: String, _ draw: () -> CGImage) -> CGImage {
        if let image = cache[key] { return image }
        let image = draw()
        cache[key] = image
        return image
    }

    // MARK: - Painting

    /// Fills every pixel inside `shape` with `color`, and its edge with `edge` if given.
    private func paint(_ c: Canvas, _ shape: OrbShape.Test, in bounds: CGRect, edge: CGColor? = nil,
                       _ color: (Int, Int) -> CGColor) {
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) where shape(x, y) {
                let onEdge = !shape(x - 1, y) || !shape(x + 1, y) || !shape(x, y - 1) || !shape(x, y + 1)
                c.fill(x, y, 1, 1, onEdge ? edge ?? color(x, y) : color(x, y))
            }
        }
    }

    /// Brushed metal from `top` to `bottom` rows, with faint streaks.
    private func brushed(_ top: CGFloat, _ bottom: CGFloat, light: CGColor, dark: CGColor) -> (Int, Int) -> CGColor {
        { x, y in
            let t = (Double(y) - top) / max(bottom - top, 1)
            let streak = Double((y * 7919 + (x / 23) * 104729) % 7) / 6 - 0.5
            return mix(mix(light, dark, t), rgb(0xffffff), max(streak, 0) * 0.12)
        }
    }

    /// Glossy gel: a gradient with a bright upper half and a soft glow at the bottom.
    private func gloss(_ top: CGFloat, _ bottom: CGFloat, _ a: CGColor, _ b: CGColor) -> (Int, Int) -> CGColor {
        { _, y in
            let t = (Double(y) - top) / max(bottom - top, 1)
            let base = mix(a, b, t)
            if t < 0.5 { return mix(base, rgb(0xffffff), 0.55 - t * 0.6) }
            return mix(base, mix(a, rgb(0xffffff), 0.3), max(0, (t - 0.8) * 1.2))
        }
    }

    private func icon(_ c: Canvas, _ rows: [String], _ x: Int, _ y: Int, _ color: CGColor, shadow: CGColor? = nil) {
        for pass in shadow == nil ? [0] : [1, 0] {
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "#" {
                    c.fill(x + column + pass, y + row + pass, 1, 1, pass == 1 ? shadow! : color)
                }
            }
        }
    }

    private static let icons: [TransportButton: [String]] = [
        .play: ["#.........", "###.......", "#####.....", "#######...", "#########.", "##########",
                "#########.", "#######...", "#####.....", "###.......", "#........."],
        .pause: ["##.##", "##.##", "##.##", "##.##", "##.##"],
        .stop: ["#####", "#####", "#####", "#####", "#####"],
        .next: ["#..#..#", "##.##.#", "#######", "##.##.#", "#..#..#"],
        .previous: ["#..#..#", "#.##.##", "#######", "#.##.##", "#..#..#"],
        .eject: ["..#..", ".###.", "#####", ".....", "#####"],
    ]

    private static let titleIcons: [TitleButton: [String]] = [
        .options: ["#####", ".###.", "..#.."],
        .minimize: ["#####"],
        .shade: ["#####", ".....", "#####"],
        .close: ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
    ]

    // MARK: - Sprites

    /// Everything that doesn't move: the shape, the empty display and the tracks.
    func background(active: Bool) -> CGImage {
        cached("background-\(active)") {
            let c = Canvas(OrbLayout.size)
            let all = CGRect(origin: .zero, size: OrbLayout.size)
            let ink = outline

            // The title tab, behind the body.
            let title: (CGColor, CGColor)
            if case .gloss(let top, let bottom, let inactiveTop, let inactiveBottom) = theme.titleStyle {
                title = active ? (top, bottom) : (inactiveTop, inactiveBottom)
            } else {
                title = active ? (theme.faceLight, theme.title) : (theme.faceLight, theme.face)
            }
            let tab = OrbLayout.titleTab
            paint(c, OrbShape.roundRect(tab, 9), in: tab, edge: ink, gloss(tab.minY, tab.minY + 16, title.0, title.1))
            let text = OrbLayout.titleText
            c.text("BITAMP", Int(text.x) + 1, Int(text.y) + 1, gel.edge)
            c.text("BITAMP", Int(text.x), Int(text.y), active ? theme.titleText : theme.titleTextInactive)

            // The foot tab, then the body over both tabs.
            let foot = OrbLayout.footTab
            paint(c, OrbShape.roundRect(foot, 9), in: foot, edge: ink,
                  brushed(foot.minY, foot.maxY, light: mix(metal.top, metal.bottom, 0.3), dark: mix(metal.bottom, theme.faceDark, 0.3)))
            let body = OrbLayout.body
            let bodyShape = OrbShape.roundRect(body, 38)
            paint(c, bodyShape, in: body, edge: ink, brushed(body.minY, body.maxY, light: metal.top, dark: metal.bottom))
            for x in Int(body.minX)..<Int(body.maxX) where bodyShape(x, Int(body.minY) + 1) && bodyShape(x - 1, Int(body.minY) + 1) && bodyShape(x + 1, Int(body.minY) + 1) {
                c.fill(x, Int(body.minY) + 1, 1, 1, white)
            }

            // The display, sunk into the body.
            let display = OrbLayout.display
            paint(c, OrbShape.roundRect(display.insetBy(dx: -1, dy: -1), 8), in: all) { _, _ in self.white }
            paint(c, OrbShape.roundRect(CGRect(x: display.minX - 1, y: display.minY - 1, width: display.width + 1, height: display.height + 1), 8), in: all) { _, _ in self.theme.faceDark }
            paint(c, OrbShape.roundRect(display, 7), in: display) { _, _ in self.theme.lcd }

            // Tracks for seeking and volume.
            let groove = OrbLayout.positionGroove
            c.fill(Int(groove.minX), Int(groove.minY), Int(groove.width), Int(groove.height), ink)
            c.fill(Int(groove.minX) + 1, Int(groove.maxY), Int(groove.width), 1, white)
            let volume = OrbLayout.volumeGroove
            c.fill(Int(volume.minX), Int(volume.minY), Int(volume.width), Int(volume.height), ink)
            c.fill(Int(volume.maxX), Int(volume.minY) + 1, 1, Int(volume.height), white)

            // The time's colon is part of the display, as on a real LCD.
            let colon = OrbLayout.timeColon
            c.fill(Int(colon.x), Int(colon.y), 2, 2, theme.lcdOn)
            c.fill(Int(colon.x), Int(colon.y) + 5, 2, 2, theme.lcdOn)
            let speaker = OrbLayout.speaker
            icon(c, ["..#", ".##", "###", ".##", "..#"], Int(speaker.x), Int(speaker.y), theme.label)
            c.fill(Int(speaker.x) + 4, Int(speaker.y) + 1, 1, 3, theme.label)
            c.fill(Int(speaker.x) + 6, Int(speaker.y), 1, 5, theme.label)

            // The orb: a brushed ring with a white rim, and a groove for the play button.
            let center = OrbLayout.orbCenter, r = OrbLayout.orbRadius
            let ring = OrbShape.circle(center, r)
            let rim = OrbShape.circle(center, r - 2)
            let ringMetal = brushed(center.y - r, center.y + r, light: mix(metal.top, white, 0.4), dark: mix(metal.bottom, theme.faceDark, 0.2))
            paint(c, ring, in: all, edge: ink) { x, y in rim(x, y) ? ringMetal(x, y) : self.white }
            paint(c, OrbShape.circle(center, OrbLayout.playRadius + 3), in: all) { _, _ in self.theme.faceDark }
            paint(c, OrbShape.circle(CGPoint(x: center.x, y: center.y + 1), OrbLayout.playRadius + 1), in: all) { _, _ in self.white }
            // The small buttons sit in shallow dimples.
            for button in TransportButton.allCases where button != .play {
                let at = OrbLayout.center(of: button)
                paint(c, OrbShape.circle(CGPoint(x: at.x, y: at.y + 1), OrbLayout.buttonRadius + 1.5), in: all) { _, _ in self.white }
                paint(c, OrbShape.circle(at, OrbLayout.buttonRadius + 1.5), in: all) { _, _ in self.theme.faceDark }
            }
            return c.image()
        }
    }

    /// A round gel button with its icon, sized by `OrbLayout.rect(of:)`.
    func transport(_ button: TransportButton, pressed: Bool) -> CGImage {
        cached("transport-\(button)-\(pressed)") {
            let rect = OrbLayout.rect(of: button)
            let c = Canvas(rect.size)
            let center = CGPoint(x: OrbLayout.center(of: button).x - rect.minX, y: OrbLayout.center(of: button).y - rect.minY)
            let r = OrbLayout.radius(of: button)
            let bounds = CGRect(origin: .zero, size: rect.size)
            let colors = pressed ? (gel.pressedTop, gel.pressedBottom) : (gel.top, gel.bottom)
            paint(c, OrbShape.circle(center, r), in: bounds, edge: gel.edge,
                  gloss(center.y - r, center.y + r, colors.0, colors.1))
            let rows = Self.icons[button]!
            let shift = pressed ? 1 : 0
            icon(c, rows, Int(center.x) - rows[0].count / 2 + shift + (button == .play ? 1 : 0),
                 Int(center.y) - rows.count / 2 + shift, theme.icon, shadow: gel.edge)
            return c.image()
        }
    }

    func titleButton(_ button: TitleButton, pressed: Bool) -> CGImage {
        cached("title-\(button)-\(pressed)") {
            let size = OrbLayout.titleButton(button).size
            let c = Canvas(size)
            let bounds = CGRect(origin: .zero, size: size)
            let colors = pressed ? (gel.pressedTop, gel.pressedBottom) : (mix(gel.top, white, 0.4), mix(gel.bottom, gel.top, 0.5))
            paint(c, OrbShape.roundRect(bounds, 3), in: bounds, edge: gel.edge, gloss(0, bounds.height, colors.0, colors.1))
            let rows = Self.titleIcons[button]!
            icon(c, rows, (Int(size.width) - rows[0].count) / 2, (Int(size.height) - rows.count) / 2, theme.icon)
            return c.image()
        }
    }

    /// A pill with a small light and a label; lit pills are blue gel.
    func toggle(_ button: ToggleButton, on: Bool, pressed: Bool) -> CGImage {
        cached("toggle-\(button)-\(on)-\(pressed)") {
            let size = OrbLayout.rect(of: button).size
            let c = Canvas(size)
            let bounds = CGRect(origin: .zero, size: size)
            let colors: (CGColor, CGColor)
            switch (on, pressed) {
            case (_, true): colors = (gel.pressedTop, gel.pressedBottom)
            case (true, false): colors = (gel.top, gel.bottom)
            case (false, false): colors = (theme.faceButton, theme.indicatorOff)
            }
            paint(c, OrbShape.roundRect(bounds, 4), in: bounds, edge: gel.edge, gloss(0, bounds.height, colors.0, colors.1))
            c.fill(3, 4, 1, 2, on ? theme.accent : theme.groove)
            let lit = on || pressed
            if lit { c.text(OrbLayout.label(of: button), 6, 3, gel.edge) }
            c.text(OrbLayout.label(of: button), 5, 2, lit ? theme.icon : theme.label)
            return c.image()
        }
    }

    func positionThumb(pressed: Bool) -> CGImage {
        cached("position-\(pressed)") { thumb(OrbLayout.positionThumb, pressed: pressed) }
    }

    func volumeThumb(pressed: Bool) -> CGImage {
        cached("volume-\(pressed)") { thumb(OrbLayout.volumeThumb, pressed: pressed) }
    }

    private func thumb(_ size: CGSize, pressed: Bool) -> CGImage {
        let c = Canvas(size)
        let bounds = CGRect(origin: .zero, size: size)
        let colors = pressed ? (gel.pressedTop, gel.pressedBottom) : (gel.top, gel.bottom)
        paint(c, OrbShape.roundRect(bounds, 3), in: bounds, edge: gel.edge, gloss(0, bounds.height, colors.0, colors.1))
        return c.image()
    }
}
