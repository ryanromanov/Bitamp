import CoreGraphics

/// Maps a slider's thumb position to a 0...1 value and back. Horizontal sliders run left
/// to right; vertical ones run bottom to top.
struct SliderGeometry {
    let track: CGRect
    /// The thumb's length along the track.
    let thumbWidth: CGFloat
    var vertical = false

    static let volume = SliderGeometry(track: Layout.volume, thumbWidth: Layout.sliderThumb.width)
    static let balance = SliderGeometry(track: Layout.balance, thumbWidth: Layout.sliderThumb.width)
    static let position = SliderGeometry(track: Layout.position, thumbWidth: Layout.positionThumb.width)

    var travel: CGFloat { (vertical ? track.height : track.width) - thumbWidth }

    /// The thumb's left edge, or top edge if vertical, for `value`, on whole pixels.
    func thumbStart(for value: Double) -> CGFloat {
        let offset = (travel * CGFloat(min(max(value, 0), 1))).rounded()
        return vertical ? track.minY + travel - offset : track.minX + offset
    }

    func value(forThumbStart start: CGFloat) -> Double {
        let offset = vertical ? track.minY + travel - start : start - track.minX
        return Double(min(max(offset / travel, 0), 1))
    }

    /// `point`'s coordinate along the track.
    func along(_ point: CGPoint) -> CGFloat {
        vertical ? point.y : point.x
    }
}

/// Balance runs -1...1 but its slider runs 0...1; values near the middle snap to center.
enum BalanceMapping {
    static let snap = 0.08

    static func balance(fromSlider value: Double) -> Double {
        let balance = value * 2 - 1
        return abs(balance) < snap ? 0 : balance
    }

    static func slider(fromBalance balance: Double) -> Double {
        (balance + 1) / 2
    }
}

enum TimeFormat {
    /// "m:ss", or "h:mm:ss" from an hour up.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(total / 60):\(twoDigits(secs))"
    }

    /// The four LCD digits: minutes and seconds, or hours and minutes past 99:59.
    static func lcdDigits(_ seconds: Double) -> [Int] {
        let total = max(0, Int(seconds.rounded(.down)))
        var (left, right) = (total / 60, total % 60)
        if left > 99 {
            (left, right) = (min(total / 3600, 99), total / 60 % 60)
        }
        return [left / 10, left % 10, right / 10, right % 10]
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
