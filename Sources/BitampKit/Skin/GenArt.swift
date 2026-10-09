import CoreGraphics

/// A `.wsz` skin's generic window frame, from the `gen.bmp` that Winamp 2.9 added for
/// windows beyond the classic three. Coordinates and the title layout follow Webamp's.
struct GenArt {
    /// One state of the title bar, cut into the pieces the bar is built from.
    struct Top {
        let left, leftEnd, centerFill, rightEnd, fill, right: CGImage
    }

    static let topHeight = 20
    static let bottomHeight = 14
    static let leftWidth = 11
    static let rightWidth = 8
    static let letterHeight = 7
    static let spaceWidth = 5
    /// Where the title's letters start in the 20-pixel bar.
    static let letterY = 4

    let activeTop, inactiveTop: Top
    let bottomLeft, bottomRight, bottomFill: CGImage
    let middleLeft, middleLeftBottom, middleRight, middleRightBottom: CGImage
    /// The close button pressed; unpressed, it's part of the top-right piece.
    let closePressed: CGImage
    private let activeLetters, inactiveLetters: [Character: CGImage]

    init?(sheet: CGImage) {
        func crop(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
            guard x + w <= sheet.width, y + h <= sheet.height else { return nil }
            return sheet.cropping(to: CGRect(x: x, y: y, width: w, height: h))
        }
        func top(_ y: Int) -> Top? {
            guard let left = crop(0, y, 25, 20), let leftEnd = crop(26, y, 25, 20),
                  let centerFill = crop(52, y, 25, 20), let rightEnd = crop(78, y, 25, 20),
                  let fill = crop(104, y, 25, 20), let right = crop(130, y, 25, 20)
            else { return nil }
            return Top(left: left, leftEnd: leftEnd, centerFill: centerFill, rightEnd: rightEnd, fill: fill, right: right)
        }
        guard let activeTop = top(0), let inactiveTop = top(21),
              let bottomLeft = crop(0, 42, 125, 14), let bottomRight = crop(0, 57, 125, 14),
              let bottomFill = crop(127, 72, 25, 14),
              let middleLeft = crop(127, 42, 11, 29), let middleLeftBottom = crop(158, 42, 11, 24),
              let middleRight = crop(139, 42, 8, 29), let middleRightBottom = crop(170, 42, 8, 24),
              let closePressed = crop(148, 42, 9, 9),
              let pixels = Pixels(sheet),
              let activeLetters = Self.letters(sheet, pixels, y: 88),
              let inactiveLetters = Self.letters(sheet, pixels, y: 96)
        else { return nil }
        self.activeTop = activeTop
        self.inactiveTop = inactiveTop
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.bottomFill = bottomFill
        self.middleLeft = middleLeft
        self.middleLeftBottom = middleLeftBottom
        self.middleRight = middleRight
        self.middleRightBottom = middleRightBottom
        self.closePressed = closePressed
        self.activeLetters = activeLetters
        self.inactiveLetters = inactiveLetters
    }

    func top(active: Bool) -> Top {
        active ? activeTop : inactiveTop
    }

    /// A letter of the title font, or nil for anything but A–Z (drawn as a space).
    func letter(_ character: Character, active: Bool) -> CGImage? {
        (active ? activeLetters : inactiveLetters)[character]
    }

    func titleWidth(_ text: String) -> Int {
        text.uppercased().reduce(0) { $0 + (letter($1, active: true)?.width ?? Self.spaceWidth) }
    }

    /// The letters A–Z sit in a row with a column of background color between each, so
    /// their widths vary from skin to skin. Measured from x = 1, as Webamp does.
    private static func letters(_ sheet: CGImage, _ pixels: Pixels, y: Int) -> [Character: CGImage]? {
        guard y + letterHeight <= sheet.height else { return nil }
        let background = pixels[0, y]
        var letters: [Character: CGImage] = [:]
        var x = 1
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            var end = x
            while end < sheet.width && pixels[end, y] != background { end += 1 }
            guard end > x, let image = sheet.cropping(to: CGRect(x: x, y: y, width: end - x, height: letterHeight))
            else { return nil }
            letters[letter] = image
            x = end + 1
        }
        return letters
    }

    /// The sheet's pixels as RGBA bytes, for finding the letters.
    private struct Pixels {
        let width: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
        }

        /// The color at (x, y), top-left origin, packed into one value for comparing.
        subscript(x: Int, y: Int) -> UInt32 {
            let i = (y * width + x) * 4
            return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
    }
}
