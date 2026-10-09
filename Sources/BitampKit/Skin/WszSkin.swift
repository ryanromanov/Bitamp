import CoreGraphics
import Foundation
import ImageIO

/// A classic `.wsz` skin: a zip of bitmaps plus `viscolor.txt` and `pledit.txt`.
///
/// Sprites are cut from the bitmaps at the classic coordinates. Anything the skin doesn't
/// include comes from `fallback`, the way the classic player fell back to its base skin.
final class WszSkin: Skin {
    enum LoadError: Error {
        case noBitmaps
    }

    let name: String
    let visColors: [CGColor]
    let eqGraphColors: [CGColor]
    let playlistColors: PlaylistColors
    private let fallback: Skin
    /// Decoded bitmaps keyed by lowercased file name without extension ("main", "cbuttons", …).
    private let sheets: [String: CGImage]
    private var cache: [SkinElement: CGImage] = [:]
    private var glyphs: [Character: CGImage] = [:]
    private(set) lazy var gen: GenArt? = sheets["gen"].flatMap(GenArt.init(sheet:))

    convenience init(url: URL, fallback: Skin = DefaultSkin()) throws {
        let archive = try ZipArchive(url: url)
        var files: [String: Data] = [:]
        for entry in archive.entries where !entry.isDirectory {
            // Skins put their files at the top level or inside one folder; names vary in case.
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            if files[name] == nil { files[name] = try? archive.contents(of: entry) }
        }
        try self.init(name: url.deletingPathExtension().lastPathComponent, files: files, fallback: fallback)
    }

    /// `files` maps lowercased file names ("main.bmp") to their contents.
    init(name: String, files: [String: Data], fallback: Skin = DefaultSkin()) throws {
        self.name = name
        self.fallback = fallback
        var sheets: [String: CGImage] = [:]
        for (file, data) in files where file.hasSuffix(".bmp") || file.hasSuffix(".png") {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            sheets[(file as NSString).deletingPathExtension] = image
        }
        guard !sheets.isEmpty else { throw LoadError.noBitmaps }
        self.sheets = sheets

        visColors = files["viscolor.txt"].flatMap { Self.parseVisColors(String(decoding: $0, as: UTF8.self)) }
            ?? fallback.visColors
        eqGraphColors = sheets["eqmain"].flatMap(Self.graphColors) ?? fallback.eqGraphColors
        playlistColors = files["pledit.txt"].map {
            Self.parsePlaylistColors(String(decoding: $0, as: UTF8.self), fallback: fallback.playlistColors)
        } ?? fallback.playlistColors
    }

    func image(for element: SkinElement) -> CGImage {
        if let image = cache[element] { return image }
        let image = sprite(for: element) ?? fallback.image(for: element)
        cache[element] = image
        return image
    }

    func glyph(for character: Character) -> CGImage {
        if let image = glyphs[character] { return image }
        let position = Self.textPosition(character) ?? Self.textPosition(" ")!
        let image = sheets["text"].flatMap {
            crop($0, CGRect(x: position.column * 5, y: position.row * 6, width: 5, height: 6))
        } ?? fallback.glyph(for: character)
        glyphs[character] = image
        return image
    }

    // MARK: - Sprites

    private func sprite(for element: SkinElement) -> CGImage? {
        switch element {
        case .digit(let digit):
            if let numbers = sheets["nums_ex"] {
                return crop(numbers, CGRect(x: digit * 9, y: 0, width: 9, height: 13))
            }
            guard let numbers = sheets["numbers"] else { return nil }
            // The classic player draws nothing for a blank digit; the background shows.
            if digit == SkinElement.blankDigit { return transparent(Layout.minus.size) }
            return crop(numbers, CGRect(x: digit * 9, y: 0, width: 9, height: 13))
        case .minus:
            if let numbers = sheets["nums_ex"] {
                return crop(numbers, CGRect(x: 99, y: 0, width: 9, height: 13))
            }
            guard let numbers = sheets["numbers"],
                  let sign = crop(numbers, CGRect(x: 20, y: 6, width: 5, height: 1))
            else { return nil }
            let cell = Canvas(Layout.minus.size)
            cell.draw(sign, 2, 6)
            return cell.image()
        default:
            break
        }
        guard let (sheet, rect) = Self.source(for: element) else {
            // Parts the classic skins don't have as sprites, like the about button, are
            // painted into the background; draw nothing over them.
            return Self.paintedIntoBackground(element) ? transparent(Self.size(of: element)) : nil
        }
        guard let image = sheets[sheet] else { return nil }
        // A skin whose bitmap is too small for a sprite (some omit the volume thumb) shows
        // nothing there, as the classic player did.
        return crop(image, rect) ?? transparent(rect.size)
    }

    private func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        guard rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height) else { return nil }
        return image.cropping(to: rect)
    }

    private func transparent(_ size: CGSize) -> CGImage {
        Canvas(size).image()
    }

    private static func paintedIntoBackground(_ element: SkinElement) -> Bool {
        switch element {
        case .about, .eqCloseButton(pressed: false), .playlistCloseButton(pressed: false),
             .eqShadeButton(pressed: false), .eqUnshadeButton(pressed: false), .eqShadeCloseButton(pressed: false),
             .playlistShadeButton(pressed: false), .playlistUnshadeButton(pressed: false):
            return true
        default: return false
        }
    }

    private static func size(of element: SkinElement) -> CGSize {
        switch element {
        case .about: return Layout.about.size
        default: return CGSize(width: 9, height: 9)
        }
    }

    /// Which bitmap a sprite comes from and where, using the classic sprite sheet layout.
    static func source(for element: SkinElement) -> (sheet: String, rect: CGRect)? {
        func r(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
        switch element {
        case .mainBackground:
            return ("main", r(0, 0, 275, 116))
        case .titleBar(let active):
            return ("titlebar", r(27, active ? 0 : 15, 275, 14))
        case .titleButton(let button, let pressed):
            let y = pressed ? 9 : 0
            switch button {
            case .options: return ("titlebar", r(0, y, 9, 9))
            case .minimize: return ("titlebar", r(9, y, 9, 9))
            case .shade: return ("titlebar", r(pressed ? 9 : 0, 18, 9, 9))
            case .close: return ("titlebar", r(18, y, 9, 9))
            }
        case .transport(let button, let pressed):
            switch button {
            case .previous: return ("cbuttons", r(0, pressed ? 18 : 0, 23, 18))
            case .play: return ("cbuttons", r(23, pressed ? 18 : 0, 23, 18))
            case .pause: return ("cbuttons", r(46, pressed ? 18 : 0, 23, 18))
            case .stop: return ("cbuttons", r(69, pressed ? 18 : 0, 23, 18))
            case .next: return ("cbuttons", r(92, pressed ? 18 : 0, 22, 18))
            case .eject: return ("cbuttons", r(114, pressed ? 16 : 0, 22, 16))
            }
        case .playStatus(let status):
            switch status {
            case .playing: return ("playpaus", r(0, 0, 9, 9))
            case .paused: return ("playpaus", r(9, 0, 9, 9))
            case .stopped: return ("playpaus", r(18, 0, 9, 9))
            }
        case .mono(let active):
            return ("monoster", r(29, active ? 0 : 12, 27, 12))
        case .stereo(let active):
            return ("monoster", r(0, active ? 0 : 12, 29, 12))
        case .volumeBackground(let level):
            return ("volume", r(0, level * 15, 68, 13))
        case .volumeThumb(let pressed):
            return ("volume", r(pressed ? 0 : 15, 422, 14, 11))
        case .balanceBackground(let level):
            return ("balance", r(9, level * 15, 38, 13))
        case .balanceThumb(let pressed):
            return ("balance", r(pressed ? 0 : 15, 422, 14, 11))
        case .positionBackground:
            return ("posbar", r(0, 0, 248, 10))
        case .positionThumb(let pressed):
            return ("posbar", r(pressed ? 278 : 248, 0, 29, 10))
        case .toggle(let button, let on, let pressed):
            switch button {
            case .repeatTrack: return ("shufrep", r(0, (on ? 30 : 0) + (pressed ? 15 : 0), 28, 15))
            case .shuffle: return ("shufrep", r(28, (on ? 30 : 0) + (pressed ? 15 : 0), 46, 15))
            case .equalizer: return ("shufrep", r(pressed ? 46 : 0, on ? 73 : 61, 23, 12))
            case .playlist: return ("shufrep", r(pressed ? 69 : 23, on ? 73 : 61, 23, 12))
            }

        case .eqBackground:
            return ("eqmain", r(0, 0, 275, 116))
        case .eqTitleBar(let active):
            return ("eqmain", r(0, active ? 134 : 149, 275, 14))
        case .eqCloseButton(pressed: true):
            return ("eqmain", r(0, 116, 9, 9))
        case .eqButton(let button, let on, let pressed):
            switch button {
            case .on: return ("eqmain", r([[10, 128], [69, 187]][on ? 1 : 0][pressed ? 1 : 0], 119, 26, 12))
            case .auto: return ("eqmain", r([[36, 154], [95, 213]][on ? 1 : 0][pressed ? 1 : 0], 119, 32, 12))
            case .presets: return ("eqmain", r(224, pressed ? 176 : 164, 44, 12))
            }
        case .eqSliderBackground(let level):
            // 28 frames in two rows of 14, from -12 dB to +12 dB.
            return ("eqmain", r(13 + (level % 14) * 15, 164 + (level / 14) * 65, 14, 63))
        case .eqSliderThumb(let pressed):
            return ("eqmain", r(0, pressed ? 176 : 164, 11, 11))
        case .eqGraphBackground:
            return ("eqmain", r(0, 294, 113, 19))
        case .eqPreampLine:
            return ("eqmain", r(0, 314, 113, 1))

        case .playlistTopLeft(let active):
            return ("pledit", r(0, active ? 0 : 21, 25, 20))
        case .playlistTitle(let active):
            return ("pledit", r(26, active ? 0 : 21, 100, 20))
        case .playlistTopTile(let active):
            return ("pledit", r(127, active ? 0 : 21, 25, 20))
        case .playlistTopRight(let active):
            return ("pledit", r(153, active ? 0 : 21, 25, 20))
        case .playlistLeftTile:
            return ("pledit", r(0, 42, 12, 29))
        case .playlistRightTile:
            return ("pledit", r(31, 42, 20, 29))
        case .playlistBottomLeft:
            return ("pledit", r(0, 72, 125, 38))
        case .playlistBottomRight:
            return ("pledit", r(126, 72, 150, 38))
        case .playlistBottomTile:
            return ("pledit", r(179, 0, 25, 38))
        case .playlistScrollThumb(let pressed):
            return ("pledit", r(pressed ? 61 : 52, 53, 8, 18))
        case .playlistCloseButton(pressed: true):
            return ("pledit", r(52, 42, 9, 9))

        case .mainShadeBackground(let active):
            return ("titlebar", r(27, active ? 29 : 42, 275, 14))
        case .mainUnshadeButton(let pressed):
            return ("titlebar", r(pressed ? 9 : 0, 27, 9, 9))
        case .mainShadePosition:
            return ("titlebar", r(0, 36, 17, 7))
        case .mainShadeThumb(let thumb):
            return ("titlebar", r([ShadeThumb.left: 17, .center: 20, .right: 23][thumb]!, 36, 3, 7))
        case .eqShadeButton(pressed: true):
            return ("eq_ex", r(1, 38, 9, 9))
        case .eqShadeBackground(let active):
            return ("eq_ex", r(0, active ? 0 : 15, 275, 14))
        case .eqUnshadeButton(pressed: true):
            return ("eq_ex", r(1, 47, 9, 9))
        case .eqShadeCloseButton(pressed: true):
            return ("eq_ex", r(11, 47, 9, 9))
        case .eqShadeVolumeThumb(let thumb):
            return ("eq_ex", r(1 + [ShadeThumb.left: 0, .center: 3, .right: 6][thumb]!, 30, 3, 7))
        case .eqShadeBalanceThumb(let thumb):
            return ("eq_ex", r(11 + [ShadeThumb.left: 0, .center: 3, .right: 6][thumb]!, 30, 3, 7))
        case .playlistShadeButton(pressed: true):
            return ("pledit", r(62, 42, 9, 9))
        case .playlistShadeLeft:
            return ("pledit", r(72, 42, 25, 14))
        case .playlistShadeTile:
            return ("pledit", r(72, 57, 25, 14))
        case .playlistShadeRight(let active):
            return ("pledit", r(99, active ? 42 : 57, 50, 14))
        case .playlistUnshadeButton(pressed: true):
            return ("pledit", r(150, 42, 9, 9))

        case .about, .eqCloseButton, .playlistCloseButton, .digit, .minus, .eqShadeButton, .eqUnshadeButton,
             .eqShadeCloseButton, .playlistShadeButton, .playlistUnshadeButton:
            return nil
        }
    }

    // MARK: - Text

    /// Where a character sits in `text.bmp`, in 5×6 cells.
    static func textPosition(_ character: Character) -> (row: Int, column: Int)? {
        if let ascii = character.asciiValue {
            switch character {
            case "A"..."Z": return (0, Int(ascii) - 65)
            case "0"..."9": return (1, Int(ascii) - 48)
            default: break
            }
        }
        return textPositions[character]
    }

    private static let textPositions: [Character: (row: Int, column: Int)] = [
        "\"": (0, 26), "@": (0, 27), " ": (0, 30),
        "…": (1, 10), ".": (1, 11), ":": (1, 12), "(": (1, 13), ")": (1, 14), "-": (1, 15),
        "'": (1, 16), "!": (1, 17), "_": (1, 18), "+": (1, 19), "\\": (1, 20), "/": (1, 21),
        "[": (1, 22), "]": (1, 23), "^": (1, 24), "&": (1, 25), "%": (1, 26), ",": (1, 27),
        "=": (1, 28), "$": (1, 29), "#": (1, 30),
        "Å": (2, 0), "Ö": (2, 1), "Ä": (2, 2), "?": (2, 3), "*": (2, 4),
        // Stand-ins for characters text.bmp doesn't have.
        ";": (1, 12), "<": (1, 13), ">": (1, 14),
    ]

    // MARK: - Colors

    /// `viscolor.txt`: 24 lines that start with "r,g,b". Anything shorter is ignored.
    static func parseVisColors(_ text: String) -> [CGColor]? {
        let colors = text.split(whereSeparator: \.isNewline).compactMap { line -> CGColor? in
            let numbers = line.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            return CGColor(
                srgbRed: CGFloat(min(numbers[0], 255)) / 255, green: CGFloat(min(numbers[1], 255)) / 255,
                blue: CGFloat(min(numbers[2], 255)) / 255, alpha: 1)
        }
        return colors.count >= 24 ? Array(colors.prefix(24)) : nil
    }

    /// `pledit.txt`: an INI file with Normal, Current, NormalBG and SelectedBG as #RRGGBB.
    static func parsePlaylistColors(_ text: String, fallback: PlaylistColors) -> PlaylistColors {
        var values: [String: CGColor] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let hex = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { continue }
            values[key] = rgb(value)
        }
        return PlaylistColors(
            normal: values["normal"] ?? fallback.normal,
            current: values["current"] ?? fallback.current,
            normalBackground: values["normalbg"] ?? fallback.normalBackground,
            selectedBackground: values["selectedbg"] ?? fallback.selectedBackground)
    }

    /// The 19 graph colors are a 1-pixel column in `eqmain.bmp` at (115, 294).
    private static func graphColors(_ eqmain: CGImage) -> [CGColor]? {
        guard eqmain.width > 115, eqmain.height >= 313,
              let column = eqmain.cropping(to: CGRect(x: 115, y: 294, width: 1, height: 19))
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: 19 * 4)
        guard let context = CGContext(
            data: &pixels, width: 1, height: 19, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(column, in: CGRect(x: 0, y: 0, width: 1, height: 19))
        return (0..<19).map { row in
            let i = row * 4
            return CGColor(
                srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
        }
    }
}
