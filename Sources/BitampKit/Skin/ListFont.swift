import CoreGraphics
import CoreText
import Foundation

/// Bitamp's original proportional pixel font for the playlist: mixed case, 7-pixel
/// capitals, 2-pixel descenders, and accented Latin letters built from a base letter plus
/// an accent. Characters it can't draw fall back to Arial (then Hiragino Sans for CJK),
/// unsmoothed, so every title still shows up in pixels.
///
/// A line is 11 pixels tall: two rows for accents over capitals, seven for capitals (and
/// ascenders), two for descenders. The baseline is under row 8.
enum ListFont {
    static let lineHeight = 11
    static let baseline = 9
    /// Rows above the glyph art, where accents over capitals go.
    static let accentRows = 2
    static let letterSpacing = 1
    static let spaceWidth = 3

    // MARK: - Measuring and drawing

    /// One drawable piece of text: a pixel glyph, or a run of characters drawn by the fallback font.
    enum Piece: Equatable {
        case glyph(rows: [String], accent: Accent?)
        case fallback(String)
    }

    /// Splits text into pixel glyphs and fallback runs.
    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var fallback = ""
        func flush() {
            if !fallback.isEmpty { pieces.append(.fallback(fallback)) }
            fallback = ""
        }
        for character in substitute(text) {
            if let glyph = glyph(for: character) {
                flush()
                pieces.append(glyph)
            } else {
                fallback.append(character)
            }
        }
        flush()
        return pieces
    }

    static func width(of text: String) -> Int {
        let parts = pieces(text)
        let total = parts.reduce(0) { $0 + width(of: $1) + letterSpacing }
        return max(0, total - letterSpacing)
    }

    /// Draws `text` with its top-left corner at (x, y) and returns where the next character would go.
    @discardableResult
    static func draw(_ text: String, in canvas: Canvas, x: Int, y: Int, color: CGColor) -> Int {
        var cursor = x
        for piece in pieces(text) {
            switch piece {
            case .glyph(let rows, let accent):
                let width = rows.map(\.count).max() ?? 0
                for (row, bits) in rows.enumerated() {
                    for (column, bit) in bits.enumerated() where bit == "#" {
                        canvas.fill(cursor + column, y + accentRows + row, 1, 1, color)
                    }
                }
                if let accent {
                    let isCapital = rows.first?.contains("#") == true
                    accent.draw(in: canvas, x: cursor, glyphWidth: width, lineY: y, overCapital: isCapital, color: color)
                }
            case .fallback(let string):
                drawFallback(string, in: canvas, x: cursor, baselineY: y + baseline, color: color)
            }
            cursor += width(of: piece) + letterSpacing
        }
        return cursor
    }

    /// The longest prefix of `text` that fits in `width` pixels, with "..." when it was cut.
    static func truncate(_ text: String, toWidth width: Int) -> String {
        guard self.width(of: text) > width else { return text }
        var prefix = text
        while !prefix.isEmpty && self.width(of: prefix + "...") > width {
            prefix.removeLast()
        }
        return prefix.isEmpty ? "" : prefix.trimmingCharacters(in: .whitespaces) + "..."
    }

    private static func width(of piece: Piece) -> Int {
        switch piece {
        case .glyph(let rows, _): return rows.map(\.count).max() ?? 0
        case .fallback(let string): return fallbackWidth(string)
        }
    }

    // MARK: - Fallback

    /// Arial at 10 points has 7-pixel capitals, matching the pixel font. Without smoothing,
    /// CJK through Arial's default fallback turns into blobs, so Hiragino Sans, whose thin
    /// strokes survive at this size, comes next.
    private static let fallbackFont: CTFont = {
        let cascade = [CTFontDescriptorCreateWithNameAndSize("HiraginoSans-W3" as CFString, 10)]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "ArialMT",
            kCTFontCascadeListAttribute: cascade,
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, 10, nil)
    }()

    private static func fallbackLine(_ string: String, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): fallbackFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    private static func fallbackWidth(_ string: String) -> Int {
        let line = fallbackLine(string, color: CGColor(gray: 1, alpha: 1))
        return Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up))
    }

    private static func drawFallback(_ string: String, in canvas: Canvas, x: Int, baselineY: Int, color: CGColor) {
        let context = canvas.context
        context.saveGState()
        // No smoothing, like text on a 1990s desktop.
        context.setShouldAntialias(false)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        // The canvas is flipped (y down); flip the text back upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(fallbackLine(string, color: color), context)
        context.restoreGState()
    }

    // MARK: - Glyphs

    /// Typographic punctuation the font draws with plain equivalents.
    static func substitute(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "‘", "’", "‚", "′": result.append("'")
            case "“", "”", "„", "″": result.append("\"")
            case "–", "—", "−": result.append("-")
            case "…": result.append("...")
            case "\t": result.append(" ")
            default: result.append(character)
            }
        }
        return result
    }

    static func glyph(for character: Character) -> Piece? {
        if character == " " { return .glyph(rows: [String(repeating: ".", count: spaceWidth)], accent: nil) }
        if let rows = glyphs[character] { return .glyph(rows: rows, accent: nil) }
        // An accented letter: a base letter plus one combining mark.
        let scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars)
        guard scalars.count == 2,
              let accent = Accent(rawValue: scalars[1].value),
              var rows = glyphs[Character(scalars[0])]
        else { return nil }
        if Character(scalars[0]) == "i" { rows = dotlessI }
        return .glyph(rows: rows, accent: accent)
    }

    enum Accent: UInt32 {
        case grave = 0x300, acute = 0x301, circumflex = 0x302, tilde = 0x303, diaeresis = 0x308,
             ring = 0x30A, cedilla = 0x327

        /// Five pixels wide, centered over the glyph; two rows above it, or for the cedilla, below.
        var rows: [String] {
            switch self {
            case .grave: return [".#...", "..#.."]
            case .acute: return ["...#.", "..#.."]
            case .circumflex: return ["..#..", ".#.#."]
            case .tilde: return [".##.#", "#..#."]
            case .diaeresis: return [".#.#.", "....."]
            case .ring: return [".###.", ".###."]
            case .cedilla: return ["..#..", ".##.."]
            }
        }

        /// Accents sit in the two rows above the letter: above the line's top for capitals,
        /// in the ascender rows for lowercase. The cedilla hangs in the descender rows.
        func draw(in canvas: Canvas, x: Int, glyphWidth: Int, lineY: Int, overCapital: Bool, color: CGColor) {
            let offset = (glyphWidth - 5) / 2
            let top: Int
            switch (self, overCapital) {
            case (.cedilla, _): top = lineY + ListFont.accentRows + 7
            case (_, true): top = lineY
            case (_, false): top = lineY + ListFont.accentRows
            }
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "#" {
                    let px = x + offset + column
                    guard px >= x && px < x + glyphWidth else { continue }
                    canvas.fill(px, top + row, 1, 1, color)
                }
            }
        }
    }

    /// "i" without its dot, for accented i.
    private static let dotlessI = [".", ".", "#", "#", "#", "#", "#"]

    /// Rows 0–6 are cap height (the x-height starts at row 2); rows 7–8 are descenders.
    static let glyphs: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": ["###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".###.", "#...#", "#....", ".###.", "....#", "#...#", ".###."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],

        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
        "b": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####."],
        "c": ["....", "....", ".###", "#...", "#...", "#...", ".###"],
        "d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
        "f": ["..##", ".#..", "####", ".#..", ".#..", ".#..", ".#.."],
        "g": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
        "h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"],
        "i": ["#", ".", "#", "#", "#", "#", "#"],
        "j": ["..#", "...", "..#", "..#", "..#", "..#", "..#", "..#", "##."],
        "k": ["#...", "#...", "#..#", "#.#.", "##..", "#.#.", "#..#"],
        "l": ["#.", "#.", "#.", "#.", "#.", "#.", ".#"],
        "m": [".......", ".......", "###.##.", "#..#..#", "#..#..#", "#..#..#", "#..#..#"],
        "n": [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"],
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        "p": [".....", ".....", "####.", "#...#", "#...#", "#...#", "####.", "#....", "#...."],
        "q": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", "....#"],
        "r": ["....", "....", "#.##", "##..", "#...", "#...", "#..."],
        "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
        "t": [".#..", ".#..", "####", ".#..", ".#..", ".#..", "..##"],
        "u": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####"],
        "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "w": [".......", ".......", "#..#..#", "#..#..#", "#..#..#", "#..#..#", ".##.##."],
        "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
        "y": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
        "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],

        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": [".#.", "##.", ".#.", ".#.", ".#.", ".#.", "###"],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],

        "!": ["#", "#", "#", "#", "#", ".", "#"],
        "\"": ["#.#", "#.#"],
        "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
        "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
        "'": ["#", "#"],
        "(": ["..#", ".#.", "#..", "#..", "#..", ".#.", "..#"],
        ")": ["#..", ".#.", "..#", "..#", "..#", ".#.", "#.."],
        "*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        ",": ["..", "..", "..", "..", "..", ".#", ".#", "#."],
        "-": ["....", "....", "....", "####"],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
        ":": [".", ".", "#", ".", ".", "#", "."],
        ";": ["..", "..", ".#", "..", "..", ".#", ".#", "#."],
        "<": ["...#", "..#.", ".#..", "#...", ".#..", "..#.", "...#"],
        "=": [".....", ".....", "#####", ".....", "#####"],
        ">": ["#...", ".#..", "..#.", "...#", "..#.", ".#..", "#..."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".####"],
        "[": ["###", "#..", "#..", "#..", "#..", "#..", "###"],
        "\\": ["#....", "#....", ".#...", "..#..", "...#.", "....#", "....#"],
        "]": ["###", "..#", "..#", "..#", "..#", "..#", "###"],
        "^": ["..#..", ".#.#.", "#...#"],
        "_": [".....", ".....", ".....", ".....", ".....", ".....", ".....", "#####"],
        "`": ["#.", ".#"],
        "{": ["..#", ".#.", ".#.", "#..", ".#.", ".#.", "..#"],
        "|": ["#", "#", "#", "#", "#", "#", "#", "#", "#"],
        "}": ["#..", ".#.", ".#.", "..#", ".#.", ".#.", "#.."],
        "~": [".....", ".....", ".##.#", "#..#."],
        "ß": [".##..", "#..#.", "#..#.", "#.#..", "#..#.", "#..#.", "#.##."],
        "Ø": [".###.", "#..##", "#.#.#", "#.#.#", "#.#.#", "##..#", ".###."],
        "ø": [".....", ".....", ".###.", "#..##", "#.#.#", "##..#", ".###."],
    ]
}
