import Foundation

/// Finds beats in the analyzer's bars, for the visualizer's pulses.
///
/// A beat is a sudden rise in the low bars (about 40-140 Hz, where kick drums and bass
/// attacks live), not a loud bass: it counts how much the bars *rose* since the last time
/// they changed (spectral flux) and calls it a beat when that is well above what it's been
/// lately, no sooner than a quarter second after the last one. A sustained bass line adds
/// nothing, and neither does singing over the top, which sits higher up.
struct BeatDetector {
    /// The bars that count: kick drums and bass attacks.
    static let lowBars = 4
    /// How many changes of the bars the recent past remembers: about three seconds.
    static let memory = 90
    /// The least flux that can be a beat, however quiet the past was.
    static let floor: Float = 0.1
    /// How many standard deviations above the recent flux makes a beat.
    static let deviations: Float = 2
    static let cooldown: TimeInterval = 0.25

    private var previous = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var recent: [Float] = []
    private var lastBeat: TimeInterval = -.infinity

    /// Looks at the bars as of `time`; returns how strong a beat it is, as a multiple of what
    /// the beat needed to be (1 is just enough), or nil if there isn't one.
    mutating func update(bars: [Float], at time: TimeInterval) -> Float? {
        // The bars only move when the analyzer does, a few times fewer than frames are drawn.
        guard bars != previous else { return nil }
        var flux: Float = 0
        for i in 0..<Self.lowBars { flux += max(0, bars[i] - previous[i]) }
        previous = bars

        var threshold = Self.floor
        if recent.count >= 20 {
            let mean = recent.reduce(0, +) / Float(recent.count)
            let variance = recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(recent.count)
            threshold = max(threshold, mean + Self.deviations * variance.squareRoot())
        }
        recent.append(flux)
        if recent.count > Self.memory { recent.removeFirst() }

        guard flux > threshold, time - lastBeat >= Self.cooldown else { return nil }
        lastBeat = time
        return flux / threshold
    }
}
