import CoreGraphics

/// Classic main-window geometry in 1× pixels, origin top-left, y growing down.
/// Matches the documented 275×116 layout so `.wsz` skins can drop in later.
enum Layout {
    static let size = CGSize(width: 275, height: 116)

    static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    static let playStatus = CGRect(x: 26, y: 28, width: 9, height: 9)
    static let timeDisplay = CGRect(x: 36, y: 26, width: 63, height: 13)
    /// A full digit cell, as in `nums_ex.bmp`; the sign itself is drawn inside it.
    static let minus = CGRect(x: 36, y: 26, width: 9, height: 13)
    static let timeDigits: [CGPoint] = [48, 60, 78, 90].map { CGPoint(x: $0, y: 26) }
    static let visualizer = CGRect(x: 24, y: 43, width: 76, height: 16)
    static let marquee = CGRect(x: 111, y: 27, width: 154, height: 6)
    static let kbps = CGRect(x: 111, y: 43, width: 15, height: 6)
    static let khz = CGRect(x: 156, y: 43, width: 10, height: 6)
    static let mono = CGRect(x: 212, y: 41, width: 27, height: 12)
    static let stereo = CGRect(x: 239, y: 41, width: 29, height: 12)
    static let volume = CGRect(x: 107, y: 57, width: 68, height: 13)
    static let balance = CGRect(x: 177, y: 57, width: 38, height: 13)
    static let position = CGRect(x: 16, y: 72, width: 248, height: 10)
    static let about = CGRect(x: 253, y: 91, width: 13, height: 15)

    static let sliderThumb = CGSize(width: 14, height: 11)
    static let positionThumb = CGSize(width: 29, height: 10)

    /// The topmost control under `point`, if any.
    static func control(at point: CGPoint) -> Control? {
        Control.all.first { $0.rect.contains(point) }
    }
}

enum TitleButton: CaseIterable {
    case options, minimize, shade, close

    var rect: CGRect {
        switch self {
        case .options: return CGRect(x: 6, y: 3, width: 9, height: 9)
        case .minimize: return CGRect(x: 244, y: 3, width: 9, height: 9)
        case .shade: return CGRect(x: 254, y: 3, width: 9, height: 9)
        case .close: return CGRect(x: 264, y: 3, width: 9, height: 9)
        }
    }
}

enum TransportButton: CaseIterable {
    case previous, play, pause, stop, next, eject

    var rect: CGRect {
        switch self {
        case .previous: return CGRect(x: 16, y: 88, width: 23, height: 18)
        case .play: return CGRect(x: 39, y: 88, width: 23, height: 18)
        case .pause: return CGRect(x: 62, y: 88, width: 23, height: 18)
        case .stop: return CGRect(x: 85, y: 88, width: 23, height: 18)
        case .next: return CGRect(x: 108, y: 88, width: 22, height: 18)
        case .eject: return CGRect(x: 136, y: 89, width: 22, height: 16)
        }
    }
}

enum ToggleButton: CaseIterable {
    case shuffle, repeatTrack, equalizer, playlist

    var rect: CGRect {
        switch self {
        case .shuffle: return CGRect(x: 164, y: 89, width: 46, height: 15)
        case .repeatTrack: return CGRect(x: 210, y: 89, width: 28, height: 15)
        case .equalizer: return CGRect(x: 219, y: 58, width: 23, height: 12)
        case .playlist: return CGRect(x: 242, y: 58, width: 23, height: 12)
        }
    }
}

/// Everything on the main window that reacts to the mouse.
enum Control: Hashable {
    case title(TitleButton)
    case transport(TransportButton)
    case toggle(ToggleButton)
    case about, volume, balance, position, timeDisplay, visualizer

    static let all: [Control] =
        TitleButton.allCases.map(Control.title)
        + TransportButton.allCases.map(Control.transport)
        + ToggleButton.allCases.map(Control.toggle)
        + [.about, .volume, .balance, .position, .timeDisplay, .visualizer]

    var rect: CGRect {
        switch self {
        case .title(let button): return button.rect
        case .transport(let button): return button.rect
        case .toggle(let button): return button.rect
        case .about: return Layout.about
        case .volume: return Layout.volume
        case .balance: return Layout.balance
        case .position: return Layout.position
        case .timeDisplay: return Layout.timeDisplay
        case .visualizer: return Layout.visualizer
        }
    }
}

/// Equalizer window geometry in 1× pixels.
enum EQLayout {
    static let size = CGSize(width: 275, height: 116)
    static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    static let close = CGRect(x: 264, y: 3, width: 9, height: 9)
    static let graph = CGRect(x: 86, y: 17, width: 113, height: 19)
    static let preamp = CGRect(x: 21, y: 38, width: 14, height: 63)
    static let thumb = CGSize(width: 11, height: 11)
    static let labelY = 104

    static func band(_ index: Int) -> CGRect {
        CGRect(x: 78 + 18 * index, y: 38, width: 14, height: 63)
    }

    static func button(_ button: EQButton) -> CGRect {
        switch button {
        case .on: return CGRect(x: 14, y: 18, width: 26, height: 12)
        case .auto: return CGRect(x: 40, y: 18, width: 32, height: 12)
        case .presets: return CGRect(x: 217, y: 18, width: 44, height: 12)
        }
    }

    enum Control: Hashable {
        case close, shade, button(EQButton), preamp, band(Int)

        static let all: [Control] = [.close, .shade, .button(.on), .button(.auto), .button(.presets), .preamp]
            + (0..<EqualizerSettings.bandCount).map(Control.band)

        var rect: CGRect {
            switch self {
            case .close: return EQLayout.close
            case .shade: return ShadeLayout.eqShadeButton
            case .button(let button): return EQLayout.button(button)
            case .preamp: return EQLayout.preamp
            case .band(let index): return EQLayout.band(index)
            }
        }
    }

    static func control(at point: CGPoint) -> Control? {
        Control.all.first { $0.rect.contains(point) }
    }
}

/// Playlist window geometry in 1× pixels. The window is 275 wide and grows in 29-pixel
/// steps from 116 tall, so the side tiles always fit exactly.
enum PlaylistLayout {
    static let width: CGFloat = 275
    static let minHeight: CGFloat = 116
    static let heightStep: CGFloat = 29
    static let defaultHeight: CGFloat = 232
    static let top: CGFloat = 20
    static let bottom: CGFloat = 38
    static let left: CGFloat = 12
    static let right: CGFloat = 20
    static let rowHeight: CGFloat = 8
    static let scrollThumb = CGSize(width: 8, height: 18)

    static func snappedHeight(_ height: CGFloat) -> CGFloat {
        minHeight + max(0, ((height - minHeight) / heightStep).rounded()) * heightStep
    }

    static func list(in size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
    }

    static func scrollTrack(in size: CGSize) -> CGRect {
        CGRect(x: size.width - 15, y: top, width: 8, height: size.height - top - bottom)
    }

    static func close(in size: CGSize) -> CGRect {
        CGRect(x: size.width - 11, y: 3, width: 9, height: 9)
    }

    static func titleBar(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: top)
    }

    static func resizeGrip(in size: CGSize) -> CGRect {
        CGRect(x: size.width - 20, y: size.height - 20, width: 20, height: 20)
    }

    /// Where the selected/total running time is printed.
    static func runningTime(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 143, y: size.height - 28)
    }

    static func miniTime(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 82, y: size.height - 15)
    }

    enum Button: CaseIterable {
        case add, remove, select, misc, list
    }

    static func rect(_ button: Button, in size: CGSize) -> CGRect {
        let y = size.height - 30
        switch button {
        case .add: return CGRect(x: 14, y: y, width: 22, height: 18)
        case .remove: return CGRect(x: 43, y: y, width: 22, height: 18)
        case .select: return CGRect(x: 72, y: y, width: 22, height: 18)
        case .misc: return CGRect(x: 101, y: y, width: 22, height: 18)
        case .list: return CGRect(x: size.width - 44, y: y, width: 22, height: 18)
        }
    }

    static func rect(_ button: TransportButton, in size: CGSize) -> CGRect {
        let offsets: [TransportButton: CGFloat] = [.previous: 0, .play: 9, .pause: 18, .stop: 27, .next: 36, .eject: 46]
        return CGRect(x: size.width - 144 + offsets[button]!, y: size.height - 16, width: 8, height: 8)
    }

    enum Control: Hashable {
        case close, shade, titleBar, list, scrollbar, button(Button), transport(TransportButton), resizeGrip
    }

    static func control(at point: CGPoint, in size: CGSize) -> Control? {
        if close(in: size).contains(point) { return .close }
        if ShadeLayout.playlistShadeButton(width: size.width).contains(point) { return .shade }
        if titleBar(in: size).contains(point) { return .titleBar }
        if list(in: size).contains(point) { return .list }
        if scrollTrack(in: size).contains(point) { return .scrollbar }
        for button in Button.allCases where rect(button, in: size).contains(point) { return .button(button) }
        for button in TransportButton.allCases where rect(button, in: size).contains(point) { return .transport(button) }
        if resizeGrip(in: size).contains(point) { return .resizeGrip }
        return nil
    }
}

/// Geometry of the 14-pixel shade strips, in 1× pixels.
enum ShadeLayout {
    static let height: CGFloat = 14
    static let thumb = CGSize(width: 3, height: 7)

    // Main window
    static let mainVisualizer = CGRect(x: 79, y: 5, width: 38, height: 5)
    /// The minus sign, two minute digits and two second digits, in text glyphs.
    static let mainTimeGlyphs: [Int] = [126, 132, 137, 147, 152]
    static let mainTimeY = 4
    static let mainTime = CGRect(x: 126, y: 3, width: 32, height: 8)
    static let mainPosition = CGRect(x: 226, y: 4, width: 17, height: 7)

    static func mainTransport(_ button: TransportButton) -> CGRect {
        switch button {
        case .previous: return CGRect(x: 168, y: 2, width: 8, height: 10)
        case .play: return CGRect(x: 176, y: 2, width: 10, height: 10)
        case .pause: return CGRect(x: 186, y: 2, width: 9, height: 10)
        case .stop: return CGRect(x: 195, y: 2, width: 9, height: 10)
        case .next: return CGRect(x: 204, y: 2, width: 10, height: 10)
        case .eject: return CGRect(x: 214, y: 2, width: 11, height: 10)
        }
    }

    /// Main-window controls in shade mode, as the same `Control`s the full window uses.
    static func mainControl(at point: CGPoint) -> Control? {
        for button in TitleButton.allCases where button.rect.contains(point) { return .title(button) }
        for button in TransportButton.allCases where mainTransport(button).contains(point) { return .transport(button) }
        if mainVisualizer.insetBy(dx: 0, dy: -2).contains(point) { return .visualizer }
        if mainTime.contains(point) { return .timeDisplay }
        if mainPosition.contains(point) { return .position }
        return nil
    }

    // Equalizer
    static let eqShadeButton = CGRect(x: 254, y: 3, width: 9, height: 9)
    static let eqVolume = CGRect(x: 61, y: 4, width: 97, height: 7)
    static let eqBalance = CGRect(x: 164, y: 4, width: 43, height: 7)

    // Playlist (measured from the right edge, since the strip can be any width)
    static func playlistShadeButton(width: CGFloat) -> CGRect {
        CGRect(x: width - 20, y: 3, width: 9, height: 9)
    }

    static func playlistUnshade(width: CGFloat) -> CGRect {
        CGRect(x: width - 19, y: 3, width: 9, height: 9)
    }

    static func playlistClose(width: CGFloat) -> CGRect {
        CGRect(x: width - 10, y: 3, width: 9, height: 9)
    }

    static func playlistTitle(width: CGFloat) -> CGRect {
        CGRect(x: 5, y: 4, width: width - 57, height: 6)
    }

    static func playlistTime(width: CGFloat) -> CGPoint {
        CGPoint(x: width - 48, y: 4)
    }
}
