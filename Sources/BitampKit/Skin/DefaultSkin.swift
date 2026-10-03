import CoreGraphics

/// Bitamp's built-in look: original pixel art drawn in code, rendered once per sprite and cached.
final class DefaultSkin: Skin {
    let visColors: [CGColor]
    let eqGraphColors: [CGColor]
    let playlistColors = PlaylistColors(
        normal: Palette.lcdOn, current: rgb(0xffffff),
        normalBackground: Palette.lcd, selectedBackground: rgb(0x1d3566))
    private var cache: [SkinElement: CGImage] = [:]
    private var glyphs: [Character: CGImage] = [:]

    init() {
        visColors = Self.makeVisColors()
        eqGraphColors = (0..<19).map { row in
            let t = Double(row) / 18
            return t < 0.5
                ? mix(rgb(0xff5a3c), rgb(0xe8d03a), t * 2)
                : mix(rgb(0xe8d03a), rgb(0x2fc8a0), (t - 0.5) * 2)
        }
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
        case .titleBar(let active): return titleBar("BITAMP", active: active, ridgesEnd: 240)
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
            c.fill(1, 5, 6, 2, Palette.lcdOn)
            return c.image()

        case .eqBackground: return eqBackground()
        case .eqTitleBar(let active): return titleBar("BITAMP EQUALIZER", active: active, ridgesEnd: 249)
        case .eqCloseButton(let pressed), .playlistCloseButton(let pressed): return titleButton(.close, pressed: pressed)
        case .eqButton(let button, let on, let pressed): return eqButton(button, on: on, pressed: pressed)
        case .eqSliderBackground(let level): return eqSliderBackground(level)
        case .eqSliderThumb(let pressed):
            let c = Canvas(EQLayout.thumb)
            thumb(c, pressed: pressed, grips: [])
            c.fill(2, 5, 7, 1, Palette.faceDark)
            c.fill(2, 6, 7, 1, Palette.faceLight)
            return c.image()
        case .eqGraphBackground: return eqGraphBackground()
        case .eqPreampLine:
            let c = Canvas(Int(EQLayout.graph.width), 1)
            for x in stride(from: 0, to: c.width, by: 2) { c.fill(x, 0, 1, 1, Palette.amberDim) }
            return c.image()

        case .playlistTopLeft(let active): return playlistTop(width: 25, active: active, leftEdge: true)
        case .playlistTopTile(let active): return playlistTop(width: 25, active: active)
        case .playlistTopRight(let active): return playlistTop(width: 25, active: active, rightEdge: true)
        case .playlistTitle(let active): return playlistTitle(active: active)
        case .playlistLeftTile: return playlistSide(width: Int(PlaylistLayout.left), left: true)
        case .playlistRightTile: return playlistSide(width: Int(PlaylistLayout.right), left: false)
        case .playlistBottomLeft: return playlistBottomLeft()
        case .playlistBottomRight: return playlistBottomRight()
        case .playlistBottomTile: return playlistBottom(width: 25)
        case .playlistScrollThumb(let pressed):
            let c = Canvas(PlaylistLayout.scrollThumb)
            thumb(c, pressed: pressed, grips: [])
            for y in [6, 8, 10] {
                c.fill(2, y, 4, 1, Palette.faceDark)
                c.fill(2, y + 1, 4, 1, Palette.faceLight)
            }
            return c.image()

        case .mainShadeBackground(let active): return mainShadeBackground(active: active)
        case .mainUnshadeButton(let pressed), .eqUnshadeButton(let pressed), .playlistUnshadeButton(let pressed):
            return unshadeButton(pressed: pressed)
        case .mainShadePosition:
            let c = Canvas(ShadeLayout.mainPosition.size)
            groove(c, 0, 1, c.width, 5)
            return c.image()
        case .mainShadeThumb, .eqShadeVolumeThumb, .eqShadeBalanceThumb:
            let c = Canvas(ShadeLayout.thumb)
            c.fill(0, 0, c.width, c.height, Palette.icon)
            c.fill(0, c.height - 1, c.width, 1, Palette.faceLight)
            return c.image()
        case .eqShadeButton(let pressed), .playlistShadeButton(let pressed):
            return titleButton(.shade, pressed: pressed)
        case .eqShadeCloseButton(let pressed):
            return titleButton(.close, pressed: pressed)
        case .eqShadeBackground(let active): return eqShadeBackground(active: active)
        case .playlistShadeLeft: return playlistShade(width: 25, lcdFrom: 4, lcdTo: 25, leftEdge: true)
        case .playlistShadeTile: return playlistShade(width: 25, lcdFrom: 0, lcdTo: 25)
        case .playlistShadeRight: return playlistShade(width: 50, lcdFrom: 0, lcdTo: 23, rightEdge: true)
        }
    }

    // MARK: - Shade mode

    private func shadeStrip(_ c: Canvas) {
        c.fill(0, 0, c.width, c.height, Palette.title)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)
    }

    private func mainShadeBackground(active: Bool) -> CGImage {
        let c = Canvas(Layout.titleBar.size)
        shadeStrip(c)
        ridges(c, 18, 74, rows: [4, 7, 10], active: active)
        let vis = ShadeLayout.mainVisualizer
        inset(c, Int(vis.minX), Int(vis.minY), Int(vis.width), Int(vis.height))
        inset(c, 125, 3, 33, 8)
        c.glyph(":", 142, ShadeLayout.mainTimeY, Palette.lcdOn)

        // Mini transport icons, matching the click areas.
        let ink = Palette.icon
        let y = 3
        c.fill(169, y + 1, 1, 6, ink)
        for i in 0..<3 { c.fill(170 + i, y + 3 - i, 1, 1 + 2 * i, ink) }
        for i in 0..<4 { c.fill(179 + i, y + i, 1, 8 - 2 * i, ink) }
        c.fill(188, y + 1, 2, 6, ink); c.fill(191, y + 1, 2, 6, ink)
        c.fill(197, y + 1, 6, 6, ink)
        for i in 0..<3 { c.fill(206 + i, y + 1 + i, 1, 5 - 2 * i, ink) }
        c.fill(209, y + 1, 1, 6, ink)
        for i in 0..<4 { c.fill(219 - i, y + 1 + i, 1 + 2 * i, 1, ink) }
        c.fill(216, y + 6, 7, 1, ink)
        return c.image()
    }

    private func unshadeButton(pressed: Bool) -> CGImage {
        let c = Canvas(9, 9)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        c.fill(2 + o, 2 + o, 5, 1, Palette.icon)
        c.fill(2 + o, 2 + o, 1, 5, Palette.icon)
        c.fill(6 + o, 2 + o, 1, 5, Palette.icon)
        c.fill(2 + o, 6 + o, 5, 1, Palette.icon)
        return c.image()
    }

    private func eqShadeBackground(active: Bool) -> CGImage {
        let c = Canvas(Layout.titleBar.size)
        shadeStrip(c)
        c.text("EQ", 6, 4, active ? Palette.amber : Palette.label)
        ridges(c, 18, 56, rows: [4, 7, 10], active: active)
        for rect in [ShadeLayout.eqVolume, ShadeLayout.eqBalance] {
            groove(c, Int(rect.minX), Int(rect.minY) + 1, Int(rect.width), 5)
        }
        ridges(c, 210, 250, rows: [4, 7, 10], active: active)
        return c.image()
    }

    private func playlistShade(width: Int, lcdFrom: Int, lcdTo: Int, leftEdge: Bool = false, rightEdge: Bool = false) -> CGImage {
        let c = Canvas(width, Int(ShadeLayout.height))
        c.fill(0, 0, width, c.height, Palette.title)
        c.fill(0, 0, width, 1, Palette.faceLight)
        c.fill(0, c.height - 1, width, 1, Palette.faceDark)
        if leftEdge { c.fill(0, 0, 1, c.height, Palette.faceLight) }
        if rightEdge { c.fill(width - 1, 0, 1, c.height, Palette.faceDark) }
        c.fill(lcdFrom, 3, lcdTo - lcdFrom, 8, Palette.lcd)
        return c.image()
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

    /// A 275×14 title bar: centered name between ridges that run from x 18 to `ridgesEnd`.
    private func titleBar(_ name: String, active: Bool, ridgesEnd: Int) -> CGImage {
        let c = Canvas(Layout.titleBar.size)
        c.fill(0, 0, c.width, c.height, Palette.title)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)

        let textWidth = PixelFont.width(of: name) - 1
        let textX = (c.width - textWidth) / 2
        for (start, end) in [(18, textX - 6), (textX + textWidth + 6, ridgesEnd)] {
            ridges(c, start, end, rows: [4, 7, 10], active: active)
        }
        c.text(name, textX, 4, active ? Palette.amber : Palette.label)
        return c.image()
    }

    private func ridges(_ c: Canvas, _ start: Int, _ end: Int, rows: [Int], active: Bool) {
        for y in rows {
            c.fill(start, y, end - start, 1, active ? Palette.amber : Palette.faceLight)
            c.fill(start, y + 1, end - start, 1, active ? Palette.amberDim : Palette.faceDark)
        }
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

    // MARK: - Equalizer

    private func eqBackground() -> CGImage {
        let c = Canvas(EQLayout.size)
        c.fill(0, 0, c.width, c.height, Palette.face)
        c.bevel(0, 0, c.width, c.height, light: Palette.faceLight, dark: Palette.faceDark)
        let graph = EQLayout.graph
        inset(c, Int(graph.minX), Int(graph.minY), Int(graph.width), Int(graph.height))

        // A dotted 0 dB line behind the band sliders.
        let zeroY = Int(EQLayout.preamp.minY) + Int(EQLayout.preamp.height) / 2
        for x in stride(from: 76, to: 256, by: 2) { c.fill(x, zeroY, 1, 1, Palette.faceLight) }

        func rightAligned(_ text: String, _ y: Int) {
            c.text(text, 75 - (PixelFont.width(of: text) - 1), y, Palette.label)
        }
        rightAligned("+12", Int(EQLayout.preamp.minY) + 3)
        rightAligned("0", zeroY - 2)
        rightAligned("-12", Int(EQLayout.preamp.maxY) - 8)

        func centered(_ text: String, under rect: CGRect) {
            c.text(text, Int(rect.midX) - (PixelFont.width(of: text) - 1) / 2, EQLayout.labelY, Palette.label)
        }
        centered("PRE", under: EQLayout.preamp)
        for (index, label) in EqualizerLabels.bands.enumerated() {
            centered(label, under: EQLayout.band(index))
        }
        return c.image()
    }

    private func eqButton(_ button: EQButton, on: Bool, pressed: Bool) -> CGImage {
        let c = Canvas(EQLayout.button(button).size)
        raised(c, pressed: pressed)
        let o = pressed ? 1 : 0
        let textY = (c.height - 5) / 2 + o
        switch button {
        case .on, .auto:
            c.fill(4 + o, (c.height - 3) / 2 + o, 3, 3, on ? Palette.amber : Palette.amberDim)
            c.text(button == .on ? "ON" : "AUTO", 9 + o, textY, on ? Palette.icon : Palette.label)
        case .presets:
            let text = "PRESETS"
            c.text(text, (c.width - PixelFont.width(of: text) + 1) / 2 + o, textY, Palette.label)
        }
        return c.image()
    }

    /// A vertical groove, lit from the middle (0 dB) to the slider's value.
    private func eqSliderBackground(_ level: Int) -> CGImage {
        let c = Canvas(EQLayout.preamp.size)
        groove(c, 4, 0, 6, c.height)
        let last = SkinElement.sliderLevels - 1
        let t = Double(level) / Double(last)  // 0 is -12 dB, 1 is +12 dB.
        let middle = c.height / 2
        let travel = c.height - Int(EQLayout.thumb.height)
        let y = Int(EQLayout.thumb.height) / 2 + Int((Double(travel) * (1 - t)).rounded())
        let color = levelColor(abs(t - 0.5) * 2)
        c.fill(5, min(y, middle), 4, abs(y - middle) + 1, color)
        return c.image()
    }

    private func eqGraphBackground() -> CGImage {
        let c = Canvas(EQLayout.graph.size)
        c.fill(0, 0, c.width, c.height, Palette.lcd)
        for x in stride(from: 0, to: c.width, by: 2) { c.fill(x, c.height / 2, 1, 1, Palette.lcdGhost) }
        return c.image()
    }

    // MARK: - Playlist

    private func playlistTop(width: Int, active: Bool, leftEdge: Bool = false, rightEdge: Bool = false) -> CGImage {
        let c = Canvas(width, Int(PlaylistLayout.top))
        c.fill(0, 0, width, c.height, Palette.title)
        c.fill(0, 0, width, 1, Palette.faceLight)
        c.fill(0, c.height - 1, width, 1, Palette.faceDark)
        if leftEdge { c.fill(0, 0, 1, c.height, Palette.faceLight) }
        if rightEdge { c.fill(width - 1, 0, 1, c.height, Palette.faceDark) }
        // The top-right corner leaves room for the shade and close buttons.
        ridges(c, leftEdge ? 6 : 0, rightEdge ? 3 : width, rows: [5, 8, 11], active: active)
        return c.image()
    }

    private func playlistTitle(active: Bool) -> CGImage {
        let c = Canvas(100, Int(PlaylistLayout.top))
        c.fill(0, 0, c.width, c.height, Palette.title)
        c.fill(0, 0, c.width, 1, Palette.faceLight)
        c.fill(0, c.height - 1, c.width, 1, Palette.faceDark)
        let name = "PLAYLIST"
        let textWidth = PixelFont.width(of: name) - 1
        let textX = (c.width - textWidth) / 2
        ridges(c, 0, textX - 6, rows: [5, 8, 11], active: active)
        ridges(c, textX + textWidth + 6, c.width, rows: [5, 8, 11], active: active)
        c.text(name, textX, 6, active ? Palette.amber : Palette.label)
        return c.image()
    }

    private func playlistSide(width: Int, left: Bool) -> CGImage {
        let c = Canvas(width, Int(PlaylistLayout.heightStep))
        c.fill(0, 0, width, c.height, Palette.face)
        if left {
            c.fill(0, 0, 1, c.height, Palette.faceLight)
            c.fill(width - 1, 0, 1, c.height, Palette.faceDark)
        } else {
            c.fill(0, 0, 1, c.height, Palette.faceLight)
            c.fill(width - 1, 0, 1, c.height, Palette.faceDark)
            c.fill(5, 0, 8, c.height, Palette.groove)
            c.fill(4, 0, 1, c.height, Palette.faceDark)
            c.fill(13, 0, 1, c.height, Palette.faceLight)
        }
        return c.image()
    }

    private func playlistBottom(width: Int) -> CGImage {
        let c = Canvas(width, Int(PlaylistLayout.bottom))
        c.fill(0, 0, width, c.height, Palette.face)
        c.fill(0, 0, width, 1, Palette.faceLight)
        c.fill(0, c.height - 1, width, 1, Palette.faceDark)
        return c.image()
    }

    private func playlistBottomLeft() -> CGImage {
        let c = Canvas(125, Int(PlaylistLayout.bottom))
        c.fill(0, 0, c.width, c.height, Palette.face)
        c.fill(0, 0, c.width, 1, Palette.faceLight)
        c.fill(0, 0, 1, c.height, Palette.faceLight)
        c.fill(0, c.height - 1, c.width, 1, Palette.faceDark)
        for (x, label) in [(14, "ADD"), (43, "REM"), (72, "SEL"), (101, "MISC")] {
            playlistButton(c, x, 8, label)
        }
        return c.image()
    }

    private func playlistBottomRight() -> CGImage {
        let c = Canvas(150, Int(PlaylistLayout.bottom))
        c.fill(0, 0, c.width, c.height, Palette.face)
        c.fill(0, 0, c.width, 1, Palette.faceLight)
        c.fill(0, c.height - 1, c.width, 1, Palette.faceDark)
        c.fill(c.width - 1, 0, 1, c.height, Palette.faceDark)

        // Running time, mini transport and mini time.
        inset(c, 5, 8, 72, 9)
        let ink = Palette.label
        let y = 22
        c.fill(6, y + 1, 1, 5, ink)                                  // Previous
        for i in 0..<3 { c.fill(7 + i, y + 3 - i, 1, 1 + 2 * i, ink) }
        for i in 0..<3 { c.fill(16 + i, y + 1 + i, 1, 5 - 2 * i, ink) } // Play
        c.fill(24, y + 1, 2, 5, ink); c.fill(27, y + 1, 2, 5, ink)      // Pause
        c.fill(33, y + 1, 5, 5, ink)                                  // Stop
        for i in 0..<3 { c.fill(42 + i, y + 1 + i, 1, 5 - 2 * i, ink) } // Next
        c.fill(45, y + 1, 1, 5, ink)
        for i in 0..<3 { c.fill(54 - i, y + 1 + i, 1 + 2 * i, 1, ink) } // Eject
        c.fill(52, y + 5, 5, 1, ink)
        inset(c, 67, 22, 32, 8)

        playlistButton(c, 106, 8, "LIST")

        // Resize grip.
        for i in 0..<4 {
            let x = 136 + i * 3
            c.fill(x, 34 - i * 3 - 1, 1, 1, Palette.faceLight)
            c.fill(x + 1, 34 - i * 3, 1, 1, Palette.faceDark)
            for j in 0..<i { c.fill(x - (j + 1) * 3, 34 - i * 3 + (j + 1) * 3 - 1, 1, 1, Palette.faceLight) }
        }
        return c.image()
    }

    private func playlistButton(_ c: Canvas, _ x: Int, _ y: Int, _ label: String) {
        c.fill(x, y, 22, 18, Palette.faceButton)
        c.bevel(x, y, 22, 18, light: Palette.faceLight, dark: Palette.faceDark)
        c.text(label, x + (22 - PixelFont.width(of: label) + 1) / 2, y + 7, Palette.label)
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
