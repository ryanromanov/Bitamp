import Foundation

enum VisMode: String, CaseIterable {
    case spectrum, oscilloscope, off
}

enum OscilloscopeStyle: String, CaseIterable {
    case dots, lines, solid
}

/// How quickly spectrum bars or peak dots drop. Rates are fractions of full height per
/// frame at 30 fps; the speeds are far apart on purpose so the choice is visible.
enum Falloff: String, CaseIterable {
    case slow, normal, fast

    /// Slow drains a full bar in about 2.8 s, normal in 0.8 s, fast in 0.17 s.
    var barRate: Float {
        switch self {
        case .slow: return 0.012
        case .normal: return 0.04
        case .fast: return 0.2
        }
    }

    var peakRate: Float {
        switch self {
        case .slow: return 0.004
        case .normal: return 0.012
        case .fast: return 0.05
        }
    }

    /// How long a peak dot waits at the top before falling.
    var peakHoldFrames: Int {
        switch self {
        case .slow: return 30
        case .normal: return 12
        case .fast: return 3
        }
    }
}

/// Settings that survive relaunching, stored in UserDefaults.
/// The window position is saved separately, by its frame autosave name.
@MainActor
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.volume: 0.75,
            Key.showPeaks: true,
            Key.scale: 2,
        ])
    }

    var volume: Double {
        get { defaults.double(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    var balance: Double {
        get { defaults.double(forKey: Key.balance) }
        set { defaults.set(newValue, forKey: Key.balance) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle) }
        set { defaults.set(newValue, forKey: Key.shuffle) }
    }

    var repeats: Bool {
        get { defaults.bool(forKey: Key.repeats) }
        set { defaults.set(newValue, forKey: Key.repeats) }
    }

    var showRemaining: Bool {
        get { defaults.bool(forKey: Key.showRemaining) }
        set { defaults.set(newValue, forKey: Key.showRemaining) }
    }

    var visMode: VisMode {
        get { value(Key.visMode) ?? .spectrum }
        set { defaults.set(newValue.rawValue, forKey: Key.visMode) }
    }

    var showPeaks: Bool {
        get { defaults.bool(forKey: Key.showPeaks) }
        set { defaults.set(newValue, forKey: Key.showPeaks) }
    }

    var barFalloff: Falloff {
        get { value(Key.barFalloff) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.barFalloff) }
    }

    var peakFalloff: Falloff {
        get { value(Key.peakFalloff) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.peakFalloff) }
    }

    var oscilloscopeStyle: OscilloscopeStyle {
        get { value(Key.oscilloscopeStyle) ?? .lines }
        set { defaults.set(newValue.rawValue, forKey: Key.oscilloscopeStyle) }
    }

    var equalizer: EqualizerSettings {
        get { decoded(Key.equalizer) ?? .flat }
        set { encode(newValue, Key.equalizer) }
    }

    var customPresets: [EqualizerPreset] {
        get { decoded(Key.customPresets) ?? [] }
        set { encode(newValue, Key.customPresets) }
    }

    /// The current track's index in the saved queue.
    var queueIndex: Int? {
        get { defaults.object(forKey: Key.queueIndex) as? Int }
        set { defaults.set(newValue, forKey: Key.queueIndex) }
    }

    /// Points per skin pixel, 1 to 4. 2 is the normal size.
    var scale: Int {
        get { min(max(defaults.integer(forKey: Key.scale), SkinnedView.scales.lowerBound), SkinnedView.scales.upperBound) }
        set { defaults.set(newValue, forKey: Key.scale) }
    }

    /// The installed skin in use, by name; nil for the default skin.
    var skinName: String? {
        get { defaults.string(forKey: Key.skinName) }
        set { defaults.set(newValue, forKey: Key.skinName) }
    }

    private func decoded<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func value<T: RawRepresentable>(_ key: String) -> T? where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:))
    }

    private enum Key {
        static let volume = "volume"
        static let balance = "balance"
        static let shuffle = "shuffle"
        static let repeats = "repeat"
        static let showRemaining = "showRemainingTime"
        static let visMode = "visualizerMode"
        static let showPeaks = "visualizerPeaks"
        static let barFalloff = "visualizerBarFalloff"
        static let peakFalloff = "visualizerPeakFalloff"
        static let oscilloscopeStyle = "oscilloscopeStyle"
        static let equalizer = "equalizer"
        static let customPresets = "equalizerPresets"
        static let queueIndex = "queueIndex"
        static let skinName = "skin"
        static let scale = "scale"
    }
}
