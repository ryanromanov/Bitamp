import Foundation

/// The scrolling song title, plus short messages that temporarily replace it.
struct Marquee {
    static let separator = "  ***  "

    var visibleWidth: Int
    private(set) var text = ""
    /// How many pixels the looped text has scrolled left.
    private(set) var offset = 0
    /// Shown instead of the title while set, e.g. "VOLUME: 75%" during a slider drag.
    var message: String?
    private var flash: (text: String, until: Date)?

    init(visibleWidth: Int) {
        self.visibleWidth = visibleWidth
    }

    var scrolls: Bool {
        PixelFont.width(of: text) > visibleWidth
    }

    /// The text and the loop it scrolls in.
    var loop: String {
        text + Self.separator
    }

    /// A temporary message, or nil to show the title.
    func overlay(at now: Date = Date()) -> String? {
        if let message { return message }
        if let flash, flash.until > now { return flash.text }
        return nil
    }

    mutating func setText(_ text: String) {
        let normalized = PixelFont.normalize(text)
        guard normalized != self.text else { return }
        self.text = normalized
        offset = 0
    }

    mutating func flash(_ text: String, for seconds: TimeInterval = 2, now: Date = Date()) {
        flash = (PixelFont.normalize(text), now.addingTimeInterval(seconds))
    }

    /// Advances the scroll by one pixel.
    mutating func tick() {
        guard scrolls else {
            offset = 0
            return
        }
        offset = (offset + 1) % PixelFont.width(of: loop)
    }
}
