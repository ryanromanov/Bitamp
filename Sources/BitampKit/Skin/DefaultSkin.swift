import CoreGraphics

/// Bitamp's built-in look: original pixel art drawn in code, rendered once per sprite and cached.
final class DefaultSkin: Skin {
    let visColors: [CGColor]
    private var cache: [SkinElement: CGImage] = [:]
    private var glyphs: [Character: CGImage] = [:]

    init() {
        visColors = Self.makeVisColors()
    }

    func image(for element: SkinElement) -> CGImage {
        if let image = cache[element] { return image }
        let image = render(element)
        cache[element] = image
        return image
    }

    func glyph(for character: Character) -> CGImage {
        if let image = glyphs[character] { return image }
        let canvas = Canvas(PixelFont.cellWidth, PixelFont.cellHeight)
        canvas.glyph(character, 0, 0, Palette.lcdOn)
        let image = canvas.image()
        glyphs[character] = image
        return image
    }

    private func render(_ element: SkinElement) -> CGImage {
        switch element {
        case .mainBackground: return background()
        case .titleBar(let active): return titleBar(active: active)
        case .titleButton(let button, let pressed): return titleButton(button, pressed: pressed)
        case .transport(let button, let pressed): return transportButton(button, pressed: pressed)
        case .playStatus(let status): return playStatus(status)
        case .mono(let active): return indicator("MONO", size: Layout.mono.size, x: 4, active: active)
        case .stereo(let active): return indicator("STEREO", size: Layout.stereo.size, x: 0, active: active)
        case .volumeBackground(let level): return volumeBackground(level)
        case .balanceBackground(let level): return balanceBackground(level)
        case .volumeThumb(let pressed), .balanceThumb(let pressed): return sliderThumb(pressed: pressed)
        case .positionBackground: return positionBackground()
        case .positionThumb(let pressed): return positionThumb(pressed: pressed)
        case .toggle(let button, let on, let pressed): return toggleButton(button, on: on, pressed: pressed)
        case .about(let pressed): return aboutButton(pressed: pressed)
        case .digit(let digit): return self.digit(digit)
        case .minus:
            let c = Canvas(Layout.minus.size)
            c.fill(0, 0, c.width, c.height, Palette.lcdOn)
            return c.image()
        }
    }

    // MARK: - Window

    private func background() -> CGImage {
        let c = Canvas(Layout.size)
        c.fill(0, 0, c.width, c.height, Palette.face)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)

        // Grip dots down the left edge.
        for y in stride(from: 24, to: 62, by: 4) {
            c.fill(13, y, 2, 2, Palette.faceDark)
            c.fill(13, y, 1, 1, Palette.faceLight)
        }

        // Time and visualizer display.
        inset(c, 22, 24, 80, 38)
        c.fill(72, 29, 2, 2, Palette.lcdOn)
        c.fill(72, 34, 2, 2, Palette.lcdOn)

        // Marquee and readouts.
        inset(c, 108, 25, 160, 10)
        inset(c, 109, 41, 19, 10)
        c.text("KBPS", 131, 43, Palette.label)
        inset(c, 154, 41, 14, 10)
        c.text("KHZ", 171, 43, Palette.label)

        // Groove above the transport row.
        c.fill(10, 85, 255, 1, Palette.faceDark)
        c.fill(10, 86, 255, 1, Palette.faceLight)
        return c.image()
    }

    /// A recessed LCD panel whose inside is exactly (x, y, w, h).
    private func inset(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fill(x - 1, y - 1, w + 2, h + 2, Palette.faceLight)
        c.fill(x - 1, y - 1, w + 1, h + 1, Palette.faceDark)
        c.fill(x, y, w, h, Palette.lcd)
    }

    private func titleBar(active: Bool) -> CGImage {
        let c = Canvas(Layout.titleBar.size)
        c.fill(0, 0, c.width, c.height, Palette.title)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)

        let name = "BITAMP"
        let textWidth = PixelFont.width(of: name) - 1
        let textX = (c.width - textWidth) / 2
        let ridgeLight = active ? Palette.amber : Palette.faceLight
        let ridgeDark = active ? Palette.amberDim : Palette.faceDark
        for (start, end) in [(18, textX - 6), (textX + textWidth + 6, 240)] {
            for y in [4, 7, 10] {
                c.fill(start, y, end - start, 1, ridgeLight)
                c.fill(start, y + 1, end - start, 1, ridgeDark)
            }
        }
        c.text(name, textX, 4, active ? Palette.amber : Palette.label)
        return c.image()
    }

    private func titleButton(_ button: TitleButton, pressed: Bool) -> CGImage {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let ink = Palette.icon
        switch button {
        case .options:
            for i in 0..<3 { c.fill(2 + o + i, 3 + o + i, 5 - 2 * i, 1, ink) }
        case .minimize:
            c.fill(2 + o, 6 + o, 5, 1, ink)
        case .shade:
            c.fill(2 + o, 2 + o, 5, 1, ink)
            c.fill(2 + o, 4 + o, 5, 1, ink)
        case .close:
            for i in 0..<5 {
                c.fill(2 + o + i, 2 + o + i, 1, 1, ink)
                c.fill(6 + o - i, 2 + o + i, 1, 1, ink)
            }
        }
        return c.image()
    }

    // MARK: - Buttons

    /// Fills a button face with a raised bevel, or a sunken one while pressed.
    private func raised(_ c: Canvas, pressed: Bool) {
        c.fill(0, 0, c.width, c.height, pressed ? Palette.facePressed : Palette.faceButton)
        if pressed {
            c.bevel(0, 0, c.width, c.height, light: Palette.faceDark, dark: Palette.faceLight)
        } else {
            c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)
        }
    }

    private func transportButton(_ button: TransportButton, pressed: Bool) -> CGImage {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let ink = Palette.icon
        switch button {
        case .previous:
            c.fill(7 + o, 5 + o, 1, 7, ink)
            triangleLeft(c, 8 + o, 5 + o, width: 4, ink)
            triangleLeft(c, 12 + o, 5 + o, width: 4, ink)
        case .play:
            triangleRight(c, 9 + o, 4 + o, width: 5, ink)
        case .pause:
            c.fill(8 + o, 5 + o, 2, 8, ink)
            c.fill(12 + o, 5 + o, 2, 8, ink)
        case .stop:
            c.fill(8 + o, 5 + o, 7, 7, ink)
        case .next:
            triangleRight(c, 6 + o, 5 + o, width: 4, ink)
            triangleRight(c, 10 + o, 5 + o, width: 4, ink)
            c.fill(14 + o, 5 + o, 1, 7, ink)
        case .eject:
            for row in 0..<5 { c.fill(10 - row + o, 4 + row + o, 1 + 2 * row, 1, ink) }
            c.fill(6 + o, 10 + o, 9, 2, ink)
        }
        return c.image()
    }

    /// A right-pointing triangle `width` wide and `2 * width - 1` tall.
    private func triangleRight(_ c: Canvas, _ x: Int, _ y: Int, width: Int, _ color: CGColor) {
        for i in 0..<width {
            c.fill(x + i, y + i, 1, 2 * (width - i) - 1, color)
        }
    }

    private func triangleLeft(_ c: Canvas, _ x: Int, _ y: Int, width: Int, _ color: CGColor) {
        for i in 0..<width {
            let inset = width - 1 - i
            c.fill(x + i, y + inset, 1, 2 * (width - inset) - 1, color)
        }
    }

    private func toggleButton(_ button: ToggleButton, on: Bool, pressed: Bool) -> CGImage {
        let c = Canvas(button.rect.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let label: String
        switch button {
        case .shuffle: label = "SHUFFLE"
        case .repeatTrack: label = "REP"
        case .equalizer: label = "EQ"
        case .playlist: label = "PL"
        }
        let ledY = (c.height - 3) / 2
        c.fill(4 + o, ledY + o, 3, 3, on ? Palette.amber : Palette.amberDim)
        c.text(label, 9 + o, (c.height - 5) / 2 + o, on ? Palette.icon : Palette.label)
        return c.image()
    }

    private func aboutButton(pressed: Bool) -> CGImage {
        let c = Canvas(Layout.about.size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        // A small original "b" mark.
        c.fill(3 + o, 2 + o, 2, 11, Palette.amber)
        c.fill(5 + o, 6 + o, 4, 2, Palette.amber)
        c.fill(8 + o, 7 + o, 2, 5, Palette.amber)
        c.fill(5 + o, 11 + o, 4, 2, Palette.amber)
        return c.image()
    }

    // MARK: - Sliders

    private func groove(_ c: Canvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.fill(x, y, w, h, Palette.faceLight)
        c.fill(x, y, w - 1, h - 1, Palette.faceDark)
        c.fill(x + 1, y + 1, w - 2, h - 2, Palette.groove)
    }

    private func volumeBackground(_ level: Int) -> CGImage {
        let c = Canvas(Layout.volume.size)
        let t = Double(level) / Double(SkinElement.sliderLevels - 1)
        groove(c, 1, 4, c.width - 2, 5)
        let fillWidth = Int((Double(c.width - 4) * t).rounded())
        c.fill(2, 5, fillWidth, 3, levelColor(t))
        return c.image()
    }

    private func balanceBackground(_ level: Int) -> CGImage {
        let c = Canvas(Layout.balance.size)
        let t = Double(level) / Double(SkinElement.sliderLevels - 1)
        groove(c, 1, 4, c.width - 2, 5)
        c.fill(2, 5, c.width - 4, 3, mix(Palette.groove, levelColor(t), 0.55))
        c.fill(c.width / 2 - 1, 5, 2, 3, Palette.faceLight)
        return c.image()
    }

    /// Green for low values, through yellow, to red.
    private func levelColor(_ t: Double) -> CGColor {
        t < 0.5
            ? mix(Palette.levelLow, Palette.levelMid, t * 2)
            : mix(Palette.levelMid, Palette.levelHigh, (t - 0.5) * 2)
    }

    private func sliderThumb(pressed: Bool) -> CGImage {
        let c = Canvas(Layout.sliderThumb)
        thumb(c, pressed: pressed, grips: [4, 7, 10])
        return c.image()
    }

    private func positionBackground() -> CGImage {
        let c = Canvas(Layout.position.size)
        groove(c, 1, 3, c.width - 2, 4)
        return c.image()
    }

    private func positionThumb(pressed: Bool) -> CGImage {
        let c = Canvas(Layout.positionThumb)
        thumb(c, pressed: pressed, grips: [10, 13, 16])
        return c.image()
    }

    private func thumb(_ c: Canvas, pressed: Bool, grips: [Int]) {
        c.fill(0, 0, c.width, c.height, pressed ? Palette.thumbPressed : Palette.faceButton)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceHighlight, dark: Palette.faceDark)
        for x in grips {
            c.fill(x, 3, 1, c.height - 6, Palette.faceDark)
            c.fill(x + 1, 3, 1, c.height - 6, Palette.faceLight)
        }
    }

    // MARK: - Display

    private func playStatus(_ status: PlayStatus) -> CGImage {
        let c = Canvas(Layout.playStatus.size)
        switch status {
        case .playing:
            triangleRight(c, 2, 0, width: 5, Palette.lcdOn)
        case .paused:
            c.fill(2, 1, 2, 7, Palette.amber)
            c.fill(5, 1, 2, 7, Palette.amber)
        case .stopped:
            c.fill(2, 2, 5, 5, Palette.stopRed)
        }
        return c.image()
    }

    private func indicator(_ label: String, size: CGSize, x: Int, active: Bool) -> CGImage {
        let c = Canvas(size)
        c.text(label, x, 3, active ? Palette.lcdOn : Palette.faceLight)
        return c.image()
    }

    /// Seven-segment digit: lit segments over faint "ghost" segments, like a real LCD.
    private func digit(_ value: Int) -> CGImage {
        let c = Canvas(9, 13)
        let segments: [Character: (Int, Int, Int, Int)] = [
            "a": (2, 0, 5, 2), "b": (7, 2, 2, 4), "c": (7, 7, 2, 4), "d": (2, 11, 5, 2),
            "e": (0, 7, 2, 4), "f": (0, 2, 2, 4), "g": (2, 5, 5, 2),
        ]
        let lit = Self.digitSegments[value] ?? ""
        for (name, r) in segments {
            c.fill(r.0, r.1, r.2, r.3, lit.contains(name) ? Palette.lcdOn : Palette.lcdGhost)
        }
        return c.image()
    }

    private static let digitSegments: [Int: String] = [
        0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
        5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg",
    ]

    private static func makeVisColors() -> [CGColor] {
        var colors = [Palette.lcd, rgb(0x14251a)]
        for i in 0..<16 {
            let t = Double(i) / 15
            colors.append(t < 0.45
                ? mix(rgb(0xff4a3d), rgb(0xffd23a), t / 0.45)
                : mix(rgb(0xffd23a), rgb(0x2fc85a), (t - 0.45) / 0.55))
        }
        for i in 0..<5 {
            colors.append(mix(Palette.lcdOn, Palette.lcdDim, Double(i) / 4))
        }
        colors.append(rgb(0xdfe6f0))
        return colors
    }
}

private enum Palette {
    static let face = rgb(0x2b2e39)
    static let faceButton = rgb(0x343846)
    static let facePressed = rgb(0x23262f)
    static let faceLight = rgb(0x4c5265)
    static let faceHighlight = rgb(0x6a7187)
    static let faceDark = rgb(0x13141a)
    static let thumbPressed = rgb(0x454b5d)
    static let title = rgb(0x22252e)
    static let groove = rgb(0x0b0c10)
    static let label = rgb(0x8d96aa)
    static let icon = rgb(0xd0d5e0)
    static let lcd = rgb(0x040b06)
    static let lcdGhost = rgb(0x0e2415)
    static let lcdOn = rgb(0x3ef06a)
    static let lcdDim = rgb(0x1a6a32)
    static let amber = rgb(0xffb23e)
    static let amberDim = rgb(0x4a3518)
    static let stopRed = rgb(0xe05050)
    static let levelLow = rgb(0x3ec84a)
    static let levelMid = rgb(0xe8d03a)
    static let levelHigh = rgb(0xe8483a)
}
