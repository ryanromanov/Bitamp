import CoreGraphics

/// The colors and drawing styles of a skin drawn in code. `DefaultSkin` draws every sprite
/// from a theme, so a new look is a new theme rather than new drawing code.
struct SkinTheme {
    enum PanelStyle {
        /// One flat color.
        case flat
        /// Brushed metal: a vertical gradient with faint horizontal streaks.
        case brushed(top: CGColor, bottom: CGColor)
    }

    enum TitleStyle {
        /// Flat bar with ridged grooves either side of the name.
        case ridges
        /// Glossy gel: a vertical gradient with a bright upper half.
        case gloss(top: CGColor, bottom: CGColor, inactiveTop: CGColor, inactiveBottom: CGColor)
    }

    enum ButtonStyle {
        /// Square buttons with a 1-pixel bevel.
        case bevel
        /// Rounded, glossy gel buttons.
        case gel(top: CGColor, bottom: CGColor, pressedTop: CGColor, pressedBottom: CGColor, edge: CGColor)
    }

    enum MainShape {
        /// The classic 275×116 main window, drawn from sprites.
        case classic
        /// The round Orb main window; see `OrbLayout`.
        case orb
    }

    /// Saved in preferences to remember the choice, as "builtin:<id>".
    var id: String
    var name: String
    var panel: PanelStyle
    var titleStyle: TitleStyle
    var buttonStyle: ButtonStyle

    var face: CGColor
    var faceButton: CGColor
    var facePressed: CGColor
    var faceLight: CGColor
    var faceHighlight: CGColor
    var faceDark: CGColor
    var thumbPressed: CGColor
    var title: CGColor
    var groove: CGColor
    /// Text printed on panels, like "KBPS".
    var label: CGColor
    /// Icons and text on buttons, and on the button when it's off or dim.
    var icon: CGColor
    var iconDim: CGColor
    var titleText: CGColor
    var titleTextInactive: CGColor
    /// MONO and STEREO when they aren't lit.
    var indicatorOff: CGColor

    var lcd: CGColor
    var lcdGhost: CGColor
    var lcdOn: CGColor
    var lcdDim: CGColor
    /// Lit LEDs, the pause sign, the about mark and the preamp line.
    var accent: CGColor
    var accentDim: CGColor
    var stopRed: CGColor
    /// Slider fills, from low to high.
    var levelLow: CGColor
    var levelMid: CGColor
    var levelHigh: CGColor

    /// The visualizer's background dot grid.
    var visGrid: CGColor
    /// Spectrum colors from the top bar row to the bottom, and the peak dots.
    var spectrum: (top: CGColor, middle: CGColor, bottom: CGColor)
    var peak: CGColor
    /// Equalizer graph, from +12 dB to -12 dB.
    var graph: (top: CGColor, middle: CGColor, bottom: CGColor)
    var playlistCurrent: CGColor
    var playlistSelected: CGColor
    var mainShape: MainShape = .classic

    /// The skins built into Bitamp, in menu order.
    static let builtIn: [SkinTheme] = [.classic, .millennium, .orb]

    static let builtInPrefix = "builtin:"

    /// The built-in theme a saved skin name refers to, if it's one.
    static func builtIn(named saved: String?) -> SkinTheme? {
        guard let saved, saved.hasPrefix(builtInPrefix) else { return saved == nil ? .classic : nil }
        return builtIn.first { builtInPrefix + $0.id == saved }
    }

    /// Bitamp's original look: charcoal panels, green LCDs, amber accents.
    static let classic = SkinTheme(
        id: "default", name: "Bitamp Default",
        panel: .flat, titleStyle: .ridges, buttonStyle: .bevel,
        face: rgb(0x2b2e39), faceButton: rgb(0x343846), facePressed: rgb(0x23262f),
        faceLight: rgb(0x4c5265), faceHighlight: rgb(0x6a7187), faceDark: rgb(0x13141a),
        thumbPressed: rgb(0x454b5d), title: rgb(0x22252e), groove: rgb(0x0b0c10),
        label: rgb(0x8d96aa), icon: rgb(0xd0d5e0), iconDim: rgb(0x8d96aa),
        titleText: rgb(0xffb23e), titleTextInactive: rgb(0x8d96aa), indicatorOff: rgb(0x4c5265),
        lcd: rgb(0x040b06), lcdGhost: rgb(0x0e2415), lcdOn: rgb(0x3ef06a), lcdDim: rgb(0x1a6a32),
        accent: rgb(0xffb23e), accentDim: rgb(0x4a3518), stopRed: rgb(0xe05050),
        levelLow: rgb(0x3ec84a), levelMid: rgb(0xe8d03a), levelHigh: rgb(0xe8483a),
        visGrid: rgb(0x14251a), spectrum: (rgb(0xff4a3d), rgb(0xffd23a), rgb(0x2fc85a)), peak: rgb(0xdfe6f0),
        graph: (rgb(0xff5a3c), rgb(0xe8d03a), rgb(0x2fc8a0)),
        playlistCurrent: rgb(0xffffff), playlistSelected: rgb(0x1d3566))

    /// Turn-of-the-millennium media player: brushed silver, blue gel, cyan on navy.
    static let millennium = SkinTheme(
        id: "millennium", name: "Bitamp Millennium",
        panel: .brushed(top: rgb(0xe6ebf2), bottom: rgb(0xa7b2c2)),
        titleStyle: .gloss(top: rgb(0x5aa0f2), bottom: rgb(0x0b3787),
                           inactiveTop: rgb(0xa9b6c9), inactiveBottom: rgb(0x66748c)),
        buttonStyle: .gel(top: rgb(0x6fb2ff), bottom: rgb(0x0e4aa8),
                          pressedTop: rgb(0x0a3a86), pressedBottom: rgb(0x2f7de0), edge: rgb(0x08275e)),
        face: rgb(0xc3cbd7), faceButton: rgb(0xd3dae4), facePressed: rgb(0xa6b0bf),
        faceLight: rgb(0xf7f9fc), faceHighlight: rgb(0xffffff), faceDark: rgb(0x6c778a),
        thumbPressed: rgb(0xd9e7f8), title: rgb(0x1a4a9e), groove: rgb(0x3f4a60),
        label: rgb(0x22304d), icon: rgb(0xffffff), iconDim: rgb(0xdbe8fa),
        titleText: rgb(0xffffff), titleTextInactive: rgb(0x4c5769), indicatorOff: rgb(0x8f9aad),
        lcd: rgb(0x06142e), lcdGhost: rgb(0x102a52), lcdOn: rgb(0x7fd9ff), lcdDim: rgb(0x2d6c96),
        accent: rgb(0x5fe1ff), accentDim: rgb(0x26476b), stopRed: rgb(0xff6060),
        levelLow: rgb(0x1f5fc9), levelMid: rgb(0x3aa8f0), levelHigh: rgb(0xa8f2ff),
        visGrid: rgb(0x0f2347), spectrum: (rgb(0xeafcff), rgb(0x5fd0ff), rgb(0x1648b8)), peak: rgb(0xffffff),
        graph: (rgb(0xeafcff), rgb(0x5fd0ff), rgb(0x2a63d4)),
        playlistCurrent: rgb(0xffffff), playlistSelected: rgb(0x1e4fa3))

    /// Millennium's colors with a freeform main window: a big play orb and a rounded body.
    static let orb: SkinTheme = {
        var theme = millennium
        theme.id = "orb"
        theme.name = "Bitamp Orb"
        theme.mainShape = .orb
        return theme
    }()
}
