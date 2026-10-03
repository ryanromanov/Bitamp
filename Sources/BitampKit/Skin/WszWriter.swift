import CoreGraphics
import Foundation
import ImageIO

/// Writes any `Skin` out as a classic `.wsz`, so Bitamp's built-in skins also work in other
/// players that read the format.
///
/// Classic bitmaps are opaque, so each sprite is flattened onto whatever sits behind it in the
/// window. Buttons the classic format paints into the title bars (close, shade) are painted in
/// the same way.
enum WszWriter {
    /// The classic sheet sizes.
    static let sheetSizes: [String: CGSize] = [
        "main": CGSize(width: 275, height: 116), "titlebar": CGSize(width: 344, height: 87),
        "cbuttons": CGSize(width: 136, height: 36), "playpaus": CGSize(width: 42, height: 9),
        "monoster": CGSize(width: 56, height: 24), "volume": CGSize(width: 68, height: 433),
        "balance": CGSize(width: 47, height: 433), "posbar": CGSize(width: 307, height: 10),
        "shufrep": CGSize(width: 92, height: 85), "nums_ex": CGSize(width: 108, height: 13),
        "text": CGSize(width: 155, height: 18), "eqmain": CGSize(width: 275, height: 315),
        "eq_ex": CGSize(width: 275, height: 56), "pledit": CGSize(width: 280, height: 186),
    ]

    /// Every sprite that has a place on a classic sheet.
    static let elements: [SkinElement] = {
        var elements: [SkinElement] = [
            .mainBackground, .positionBackground, .eqBackground, .eqGraphBackground, .eqPreampLine,
            .playlistLeftTile, .playlistRightTile, .playlistBottomLeft, .playlistBottomRight, .playlistBottomTile,
            .mainShadePosition, .playlistShadeTile, .eqShadeButton(pressed: true), .eqUnshadeButton(pressed: true),
            .eqShadeCloseButton(pressed: true), .eqCloseButton(pressed: true), .playlistCloseButton(pressed: true),
            .playlistShadeButton(pressed: true), .playlistUnshadeButton(pressed: true),
        ]
        for flag in [false, true] {
            elements += [
                .titleBar(active: flag), .mono(active: flag), .stereo(active: flag),
                .volumeThumb(pressed: flag), .balanceThumb(pressed: flag), .positionThumb(pressed: flag),
                .eqTitleBar(active: flag), .eqSliderThumb(pressed: flag), .playlistTopLeft(active: flag),
                .playlistTitle(active: flag), .playlistTopTile(active: flag), .playlistTopRight(active: flag),
                .playlistScrollThumb(pressed: flag), .mainShadeBackground(active: flag),
                .mainUnshadeButton(pressed: flag), .eqShadeBackground(active: flag),
                .playlistShadeLeft(active: flag), .playlistShadeRight(active: flag),
            ]
            elements += TitleButton.allCases.map { .titleButton($0, pressed: flag) }
            elements += TransportButton.allCases.map { .transport($0, pressed: flag) }
            for on in [false, true] {
                elements += ToggleButton.allCases.map { .toggle($0, on: on, pressed: flag) }
                elements += [EQButton.on, .auto, .presets].map { .eqButton($0, on: on, pressed: flag) }
            }
        }
        elements += [PlayStatus.playing, .paused, .stopped].map { .playStatus($0) }
        for thumb in [ShadeThumb.left, .center, .right] {
            elements += [.mainShadeThumb(thumb), .eqShadeVolumeThumb(thumb), .eqShadeBalanceThumb(thumb)]
        }
        elements += (0..<SkinElement.sliderLevels).flatMap {
            [SkinElement.volumeBackground(level: $0), .balanceBackground(level: $0), .eqSliderBackground(level: $0)]
        }
        return elements
    }()

    // MARK: - Flattening

    /// What a sprite sits on in the window, and where, so its transparent parts can be filled in.
    static func backdrop(of element: SkinElement) -> (SkinElement, CGPoint)? {
        switch element {
        case .titleButton(let button, _): return (.titleBar(active: true), button.rect.origin)
        case .transport(let button, _): return (.mainBackground, button.rect.origin)
        case .toggle(let button, _, _): return (.mainBackground, button.rect.origin)
        case .playStatus: return (.mainBackground, Layout.playStatus.origin)
        case .mono: return (.mainBackground, Layout.mono.origin)
        case .stereo: return (.mainBackground, Layout.stereo.origin)
        case .digit: return (.mainBackground, Layout.timeDigits[0])
        case .minus: return (.mainBackground, Layout.minus.origin)
        case .volumeBackground: return (.mainBackground, Layout.volume.origin)
        case .balanceBackground: return (.mainBackground, Layout.balance.origin)
        case .positionBackground: return (.mainBackground, Layout.position.origin)
        case .volumeThumb: return (.volumeBackground(level: 13), CGPoint(x: 27, y: 1))
        case .balanceThumb: return (.balanceBackground(level: 0), CGPoint(x: 12, y: 1))
        case .positionThumb: return (.positionBackground, CGPoint(x: 0, y: 0))

        case .eqButton(let button, _, _): return (.eqBackground, EQLayout.button(button).origin)
        case .eqSliderBackground: return (.eqBackground, EQLayout.band(0).origin)
        case .eqSliderThumb: return (.eqSliderBackground(level: 13), CGPoint(x: 1, y: 26))
        case .eqGraphBackground: return (.eqBackground, EQLayout.graph.origin)
        case .eqPreampLine: return (.eqGraphBackground, CGPoint(x: 0, y: 9))
        case .eqCloseButton: return (.eqTitleBar(active: true), EQLayout.close.origin)
        case .eqShadeButton: return (.eqTitleBar(active: true), ShadeLayout.eqShadeButton.origin)

        case .playlistScrollThumb: return (.playlistRightTile, CGPoint(x: 5, y: 0))
        case .playlistCloseButton: return (.playlistTopRight(active: true), CGPoint(x: 14, y: 3))
        case .playlistShadeButton: return (.playlistTopRight(active: true), CGPoint(x: 5, y: 3))
        case .playlistUnshadeButton: return (.playlistShadeRight(active: true), CGPoint(x: 31, y: 3))

        case .mainUnshadeButton: return (.mainShadeBackground(active: true), TitleButton.shade.rect.origin)
        case .mainShadePosition: return (.mainShadeBackground(active: true), ShadeLayout.mainPosition.origin)
        case .mainShadeThumb: return (.mainShadePosition, CGPoint(x: 7, y: 0))
        case .eqUnshadeButton: return (.eqShadeBackground(active: true), ShadeLayout.eqShadeButton.origin)
        case .eqShadeCloseButton: return (.eqShadeBackground(active: true), EQLayout.close.origin)
        case .eqShadeVolumeThumb: return (.eqShadeBackground(active: true), ShadeLayout.eqVolume.origin)
        case .eqShadeBalanceThumb: return (.eqShadeBackground(active: true), ShadeLayout.eqBalance.origin)

        default: return nil  // Backgrounds and tiles are opaque already.
        }
    }

    /// Buttons the classic format paints into a background rather than drawing as sprites.
    static func paintedIn(_ element: SkinElement) -> [(SkinElement, CGPoint)] {
        switch element {
        case .mainBackground:
            return [(.about(pressed: false), Layout.about.origin)]
        case .eqTitleBar:
            return [(.eqShadeButton(pressed: false), ShadeLayout.eqShadeButton.origin),
                    (.eqCloseButton(pressed: false), EQLayout.close.origin)]
        case .eqShadeBackground:
            return [(.eqUnshadeButton(pressed: false), ShadeLayout.eqShadeButton.origin),
                    (.eqShadeCloseButton(pressed: false), EQLayout.close.origin)]
        case .playlistTopRight:
            return [(.playlistShadeButton(pressed: false), CGPoint(x: 5, y: 3)),
                    (.playlistCloseButton(pressed: false), CGPoint(x: 14, y: 3))]
        case .playlistShadeRight:
            return [(.playlistUnshadeButton(pressed: false), CGPoint(x: 31, y: 3)),
                    (.playlistCloseButton(pressed: false), CGPoint(x: 40, y: 3))]
        default:
            return []
        }
    }

    /// A sprite as it goes into the `.wsz`: on its backdrop, with painted-in buttons, opaque.
    static func flattened(_ element: SkinElement, from skin: Skin) -> CGImage {
        let sprite = skin.image(for: element)
        let canvas = Canvas(sprite.width, sprite.height)
        canvas.fill(0, 0, sprite.width, sprite.height, rgb(0x000000))
        if let (backdrop, at) = backdrop(of: element) {
            canvas.draw(flattened(backdrop, from: skin), -Int(at.x), -Int(at.y))
        }
        canvas.draw(sprite, 0, 0)
        for (button, at) in paintedIn(element) {
            canvas.draw(skin.image(for: button), at: at)
        }
        return canvas.image()
    }

    // MARK: - Sheets and files

    /// The classic bitmaps, keyed by sheet name.
    static func sheets(for skin: Skin) -> [String: CGImage] {
        var canvases: [String: Canvas] = [:]
        for (name, size) in sheetSizes {
            let canvas = Canvas(size)
            canvas.fill(0, 0, canvas.width, canvas.height, rgb(0x000000))
            canvases[name] = canvas
        }
        for element in elements {
            guard let (sheet, rect) = WszSkin.source(for: element), let canvas = canvases[sheet] else { continue }
            canvas.draw(flattened(element, from: skin), at: rect.origin)
        }

        // Digits 0–9, a blank cell and the minus sign, in nums_ex.bmp.
        let numbers = canvases["nums_ex"]!
        for digit in 0...SkinElement.blankDigit {
            numbers.draw(flattened(.digit(digit), from: skin), digit * 9, 0)
        }
        numbers.draw(flattened(.minus, from: skin), 99, 0)

        // Text glyphs on the marquee's background color.
        let text = canvases["text"]!
        let marquee = Canvas(1, 1)
        marquee.draw(flattened(.mainBackground, from: skin), -Int(Layout.marquee.minX) - 1, -Int(Layout.marquee.minY) - 1)
        text.fill(0, 0, text.width, text.height, marquee.pixelColor(0, 0))
        for character in Array(PixelFont.glyphs.keys) + [" "] {
            guard let position = WszSkin.textPosition(character) else { continue }
            text.draw(skin.glyph(for: character), position.column * 5, position.row * 6)
        }

        // The equalizer graph's colors: a 1-pixel column in eqmain.bmp at (115, 294).
        let eqmain = canvases["eqmain"]!
        for (row, color) in skin.eqGraphColors.prefix(19).enumerated() {
            eqmain.fill(115, 294 + row, 1, 1, color)
        }
        return canvases.mapValues { $0.image() }
    }

    /// Every file in the `.wsz`: lowercase file names, as classic skins use.
    static func files(for skin: Skin) -> [String: Data] {
        var files: [String: Data] = [:]
        for (name, image) in sheets(for: skin) {
            files["\(name).bmp"] = bmp(image)
        }
        files["viscolor.txt"] = Data(skin.visColors.map { color -> String in
            let (r, g, b) = components(color)
            return "\(r),\(g),\(b)"
        }.joined(separator: "\r\n").utf8)
        let colors = skin.playlistColors
        files["pledit.txt"] = Data("""
            [Text]\r
            Normal=\(hex(colors.normal))\r
            Current=\(hex(colors.current))\r
            NormalBG=\(hex(colors.normalBackground))\r
            SelectedBG=\(hex(colors.selectedBackground))\r
            Font=Arial\r

            """.utf8)
        return files
    }

    /// Writes the skin as a `.wsz` (a zip of its files) at `url`.
    static func write(_ skin: Skin, to url: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wsz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = files(for: skin)
        for (name, data) in files {
            try data.write(to: folder.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-X", url.path] + files.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A 24-bit, bottom-up Windows bitmap: the most widely readable form, which classic
    /// players expect. (ImageIO writes top-down bitmaps, which some older tools reject.)
    static func bmp(_ image: CGImage) -> Data {
        let (width, height) = (image.width, image.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rowSize = (width * 3 + 3) & ~3  // Rows are padded to 4 bytes.
        let pixelBytes = rowSize * height
        var data = Data()
        func append16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
        func append32(_ value: Int) { append16(value & 0xffff); append16(value >> 16 & 0xffff) }
        data.append(contentsOf: Array("BM".utf8))
        append32(54 + pixelBytes); append32(0); append32(54)        // File header.
        append32(40); append32(width); append32(height)             // Info header: positive height = bottom-up.
        append16(1); append16(24); append32(0); append32(pixelBytes)
        append32(2835); append32(2835); append32(0); append32(0)    // 72 dpi, no palette.
        var row = [UInt8](repeating: 0, count: rowSize)
        for y in stride(from: height - 1, through: 0, by: -1) {     // The bottom row comes first.
            for x in 0..<width {
                let i = (y * width + x) * 4
                row[x * 3] = rgba[i + 2]; row[x * 3 + 1] = rgba[i + 1]; row[x * 3 + 2] = rgba[i]  // BGR
            }
            data.append(contentsOf: row)
        }
        return data
    }

    private static func components(_ color: CGColor) -> (Int, Int, Int) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0]
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return c.count >= 3 ? (byte(c[0]), byte(c[1]), byte(c[2])) : (byte(c[0]), byte(c[0]), byte(c[0]))
    }

    private static func hex(_ color: CGColor) -> String {
        let (r, g, b) = components(color)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Canvas {
    /// The color of one pixel (top-left origin).
    func pixelColor(_ x: Int, _ y: Int) -> CGColor {
        let image = image()
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
