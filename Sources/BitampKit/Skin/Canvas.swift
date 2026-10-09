import CoreGraphics

/// A 1× RGBA bitmap with a top-left origin and no antialiasing, for pixel art.
final class Canvas {
    let width: Int
    let height: Int
    let context: CGContext

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
        context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    convenience init(_ size: CGSize) {
        self.init(Int(size.width), Int(size.height))
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(color)
        context.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    /// A 1px raised edge: `light` on the top and left, `dark` on the bottom and right.
    func bevel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, light: CGColor, dark: CGColor) {
        fill(x, y, w, 1, light)
        fill(x, y, 1, h, light)
        fill(x, y + h - 1, w, 1, dark)
        fill(x + w - 1, y, 1, h, dark)
    }

    /// Draws what `body` draws into a layer, then lays it on in greys: each color turned
    /// grey, its contrast with what's behind it softened, so a control keeps all its detail
    /// but looks locked. For controls that do nothing right now, on light or dark skins.
    func locked(_ body: (Canvas) -> Void) {
        let layer = Canvas(width, height)
        body(layer)
        guard let source = layer.context.data, let target = context.data else { return }
        let from = source.bindMemory(to: UInt8.self, capacity: layer.context.bytesPerRow * height)
        let to = target.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        func luminance(_ p: UnsafeMutablePointer<UInt8>, _ i: Int, _ alpha: Double) -> Double {
            (0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])) / alpha
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * layer.context.bytesPerRow + x * 4, j = y * context.bytesPerRow + x * 4
                let alpha = Double(from[i + 3]) / 255
                guard alpha > 0 else { continue }
                let behind = luminance(to, j, 1)
                let grey = behind + (luminance(from, i, alpha) - behind) * 0.6
                for k in 0..<3 {
                    to[j + k] = UInt8(min(255, max(0, Double(to[j + k]) * (1 - alpha) + grey * alpha)).rounded())
                }
            }
        }
    }

    /// Draws `image` upright with its top-left corner at (x, y).
    func draw(_ image: CGImage, _ x: Int, _ y: Int) {
        context.saveGState()
        context.translateBy(x: CGFloat(x), y: CGFloat(y + image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    func draw(_ image: CGImage, at point: CGPoint) {
        draw(image, Int(point.x), Int(point.y))
    }

    func glyph(_ character: Character, _ x: Int, _ y: Int, _ color: CGColor) {
        for (row, bits) in PixelFont.rows(for: character).enumerated() {
            for (column, bit) in bits.enumerated() where bit == "#" {
                fill(x + column, y + row, 1, 1, color)
            }
        }
    }

    func text(_ text: String, _ x: Int, _ y: Int, _ color: CGColor) {
        for (index, character) in PixelFont.normalize(text).enumerated() {
            glyph(character, x + index * PixelFont.cellWidth, y, color)
        }
    }

    /// A window name on a glossy title bar. White text on the bright shine gets a soft dark
    /// halo and a drop shadow; dark text gets a light line beneath it, pressed into the bar.
    func glossTitle(_ text: String, _ x: Int, _ y: Int, color: CGColor, shadow: CGColor, dark: Bool) {
        if dark {
            textHalo(text, x, y, offsets: [(0, 1)], CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        } else {
            textHalo(text, x, y, offsets: [(1, 0), (-1, 0), (0, 1), (0, -1)], shadow.copy(alpha: 0.55)!)
            self.text(text, x + 1, y + 1, shadow)
        }
        self.text(text, x, y, color)
    }

    /// Fills each pixel within `offsets` of the text's lit pixels once, so a translucent
    /// color doesn't build up where offsets overlap.
    func textHalo(_ text: String, _ x: Int, _ y: Int, offsets: [(Int, Int)], _ color: CGColor) {
        var pixels = Set<[Int]>()
        for (index, character) in PixelFont.normalize(text).enumerated() {
            for (row, bits) in PixelFont.rows(for: character).enumerated() {
                for (column, bit) in bits.enumerated() where bit == "#" {
                    for (dx, dy) in offsets { pixels.insert([x + index * PixelFont.cellWidth + column + dx, y + row + dy]) }
                }
            }
        }
        for pixel in pixels { fill(pixel[0], pixel[1], 1, 1, color) }
    }

    /// Text with 1px between each glyph's lit columns instead of fixed cells, for labels
    /// that need to fit a small button.
    func compactText(_ text: String, _ x: Int, _ y: Int, _ color: CGColor) {
        var x = x
        for character in PixelFont.normalize(text) {
            let rows = PixelFont.compactRows(for: character)
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "#" {
                    fill(x + column, y + row, 1, 1, color)
                }
            }
            x += rows[0].count + 1
        }
    }

    func image() -> CGImage {
        context.makeImage()!
    }
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1)
}

/// Linear blend from `a` (t = 0) to `b` (t = 1) in sRGB.
func mix(_ a: CGColor, _ b: CGColor, _ t: Double) -> CGColor {
    let ca = a.components ?? [0, 0, 0, 1]
    let cb = b.components ?? [0, 0, 0, 1]
    let t = CGFloat(min(max(t, 0), 1))
    return CGColor(
        srgbRed: ca[0] + (cb[0] - ca[0]) * t,
        green: ca[1] + (cb[1] - ca[1]) * t,
        blue: ca[2] + (cb[2] - ca[2]) * t,
        alpha: 1)
}
