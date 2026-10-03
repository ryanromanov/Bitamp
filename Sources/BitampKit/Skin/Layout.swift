import CoreGraphics

/// Classic main-window geometry in 1× pixels, origin top-left, y growing down.
/// Matches the documented 275×116 layout so `.wsz` skins can drop in later.
enum Layout {
    static let size = CGSize(width: 275, height: 116)

    static let titleBar = CGRect(x: 0, y: 0, width: 275, height: 14)
    static let playStatus = CGRect(x: 26, y: 28, width: 9, height: 9)
    static let timeDisplay = CGRect(x: 36, y: 26, width: 63, height: 13)
    static let minus = CGRect(x: 37, y: 31, width: 6, height: 2)
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
