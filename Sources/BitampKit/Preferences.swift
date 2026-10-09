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

    var retroSound: RetroSound {
        get { value(Key.retroSound) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.retroSound) }
    }

    var chipBlend: ChipBlend {
        get { value(Key.chipBlend) ?? .low }
        set { defaults.set(newValue.rawValue, forKey: Key.chipBlend) }
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

    /// Ids of the Expansion Paks the user has ejected. Every Pak starts inserted.
    var ejectedPaks: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.ejectedPaks) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.ejectedPaks) }
    }

    /// The current track's index in the saved queue.
    var queueIndex: Int? {
        get { defaults.object(forKey: Key.queueIndex) as? Int }
        set { defaults.set(newValue, forKey: Key.queueIndex) }
    }

    /// Points per skin pixel, one of `SkinnedView.scales`. 2 is the normal size.
    var scale: CGFloat {
        get { SkinnedView.nearestScale(to: defaults.double(forKey: Key.scale)) }
        set { defaults.set(Double(newValue), forKey: Key.scale) }
    }

    /// macOS's soft drop shadow around each window. Off by default: the classic windows had none.
    var windowShadows: Bool {
        get { defaults.bool(forKey: Key.windowShadows) }
        set { defaults.set(newValue, forKey: Key.windowShadows) }
    }

    /// Whether clicking one of Bitamp's windows brings all of them forward, past other apps',
    /// as in Winamp. Off by default: macOS brings forward only the window clicked.
    var raiseAllWindows: Bool {
        get { defaults.bool(forKey: Key.raiseAllWindows) }
        set { defaults.set(newValue, forKey: Key.raiseAllWindows) }
    }

    /// The skin in use: "builtin:<id>" for a built-in skin, an installed skin's name, or nil
    /// for the default.
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
        static let retroSound = "retroSound"
        static let chipBlend = "chiptuneBlend"
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
        static let windowShadows = "windowShadows"
        static let raiseAllWindows = "raiseAllWindows"
        static let ejectedPaks = "ejectedPaks"
    }
}

/// Bitamp 0.3 and earlier had the bundle ID dev.bitamp.Bitamp, and macOS keeps settings
/// per bundle ID. This brings them over to the new ID once, before anything reads them.
public enum OldSettings {
    static let domain = "dev.bitamp.Bitamp"
    static let copiedKey = "copiedSettingsFromDevBitamp"

    public static func copyIfNeeded(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: copiedKey) else { return }
        copy(defaults.persistentDomain(forName: domain) ?? [:], into: defaults)
    }

    /// Copies each old setting the new ID doesn't have yet.
    static func copy(_ old: [String: Any], into defaults: UserDefaults) {
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: copiedKey)
    }
}
