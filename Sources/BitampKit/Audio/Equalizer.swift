import Foundation

/// The 10-band equalizer's state, in decibels.
struct EqualizerSettings: Codable, Equatable {
    static let range: ClosedRange<Float> = -12...12
    static let bandCount = 10

    var enabled = true
    var preamp: Float = 0
    var bands = [Float](repeating: 0, count: bandCount)

    static let flat = EqualizerSettings()

    /// Clamps every value into `range` and pads or trims to ten bands.
    var clamped: EqualizerSettings {
        var copy = self
        copy.preamp = Self.clamp(preamp)
        copy.bands = (bands + [Float](repeating: 0, count: Self.bandCount)).prefix(Self.bandCount).map(Self.clamp)
        return copy
    }

    static func clamp(_ value: Float) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct EqualizerPreset: Codable, Equatable {
    var name: String
    var preamp: Float
    var bands: [Float]

    func apply(to settings: EqualizerSettings) -> EqualizerSettings {
        var settings = settings
        settings.preamp = preamp
        settings.bands = bands
        return settings.clamped
    }

    /// Bitamp's own starting points. Boosting presets lower the preamp to leave headroom.
    /// Bands: 60, 170, 310, 600 Hz, 1, 3, 6, 12, 14, 16 kHz.
    static let builtIn: [EqualizerPreset] = [
        EqualizerPreset(name: "Flat", preamp: 0, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Bass Boost", preamp: -5, bands: [7, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Treble Boost", preamp: -5, bands: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        EqualizerPreset(name: "Bass & Treble", preamp: -5, bands: [6, 5, 2, 0, -2, -1, 1, 4, 5, 6]),
        EqualizerPreset(name: "Rock", preamp: -4, bands: [5, 3, -2, -4, -1, 2, 4, 5, 5, 5]),
        EqualizerPreset(name: "Pop", preamp: -3, bands: [-1, 2, 4, 5, 3, 0, -1, -1, -1, -1]),
        EqualizerPreset(name: "Dance", preamp: -5, bands: [7, 5, 2, 0, 0, -3, -4, -4, 0, 0]),
        EqualizerPreset(name: "Jazz", preamp: -2, bands: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        EqualizerPreset(name: "Classical", preamp: 0, bands: [0, 0, 0, 0, 0, 0, -3, -4, -4, -5]),
        EqualizerPreset(name: "Vocal", preamp: -3, bands: [-2, -3, -2, 1, 4, 4, 3, 1, 0, -1]),
        EqualizerPreset(name: "Loudness", preamp: -5, bands: [6, 4, 0, -1, -2, 0, -1, 3, 5, 6]),
        EqualizerPreset(name: "Small Speakers", preamp: -4, bands: [-4, 4, 5, 3, 1, 0, 1, 2, 0, -2]),
    ]
}

/// Labels for the band sliders, matching `PlayerEngine.eqFrequencies`.
enum EqualizerLabels {
    static let bands = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
    static let names = ["60 HZ", "170 HZ", "310 HZ", "600 HZ", "1 KHZ", "3 KHZ", "6 KHZ", "12 KHZ", "14 KHZ", "16 KHZ"]

    static func decibels(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == 0 ? "0 DB" : String(format: "%+.1f DB", rounded)
    }
}
