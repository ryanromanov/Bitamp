import Foundation

/// A sudden rise in how much is going on in the sound, as the analyzer saw it at `time`
/// (seconds on the system's uptime clock): spectral flux over the audible range.
struct Onset {
    var time: Double
    var strength: Float
}

/// Finds the beat of the music, for the visualizer's pulses.
///
/// Reacting to every sudden low note fires on a piano as readily as on a kick drum. A beat is
/// something that keeps time, so this works out the tempo first and only believes onsets that
/// fall on it:
///  1. The onsets are kept as an envelope, 50 values a second.
///  2. Every half second the last six seconds are autocorrelated: a steady beat shows up as a
///     lag at which the envelope matches itself. That lag, between 60 and 180 beats a minute and
///     leaning toward the usual middle, is the tempo, and how strongly it matches says how sure
///     to be. With no steady beat, there is no tempo and no pulses.
///  3. A comb laid over the last few seconds finds where the beats fall (the anchor).
///  4. An onset that stands out from the last second or two and lands within a seventh of a
///     beat of the grid is a beat. It is reported when it happens, not when it was predicted,
///     so pulses are on the actual hit; and it nudges the grid, which follows small drifts.
struct BeatTracker {
    static let rate = 50.0
    private static let size = 512
    private static let window = 300
    private static let minLag = 17
    private static let maxLag = 50
    /// How sure the tempo must be to be believed, and how unsure before it's dropped.
    static let lockAt: Float = 0.25
    static let dropAt: Float = 0.12
    /// How close to the grid an onset must be, as a fraction of a beat.
    static let tolerance = 0.15

    private var envelope = [Float](repeating: 0, count: size)
    private var newest = -1
    private var lastOnsetBin: Int?
    private var lastAnalysis = -Double.infinity
    private var firstOnset: Double?
    /// The last few seconds of onsets, for picking out the ones that stand out.
    private var recent: [Onset] = []
    /// The time of the latest onset already looked at.
    private var examined = -Double.infinity
    private var lastOnsetTime = -Double.infinity
    private var lastBeat = -Double.infinity
    /// How many analyses in a row have found a tempo sure enough to believe: a tempo has to
    /// keep turning up before it counts.
    private var believed = 0
    /// How strong beats have been lately, so a beat can be called hard or soft by comparison.
    private var typical: Float = 0

    /// The seconds between beats, or nil when there's no steady beat.
    private(set) var period: Double?
    /// The time of some beat; others are whole periods from it.
    private var anchor = 0.0
    /// How sure the tempo is, 0 to about 1.
    private(set) var confidence: Float = 0

    var locked: Bool { period != nil }

    private func bin(_ time: Double) -> Int { Int((time * Self.rate).rounded(.down)) }

    private func value(_ b: Int) -> Float {
        guard b >= 0, b <= newest, newest - b < Self.size else { return 0 }
        return envelope[b % Self.size]
    }

    private mutating func advance(to target: Int) {
        if newest < 0 { newest = target - 1 }
        if target - newest > Self.size { newest = target - Self.size }
        while newest < target {
            newest += 1
            envelope[newest % Self.size] = 0
        }
    }

    mutating func add(_ onsets: [Onset]) {
        for onset in onsets {
            let target = bin(onset.time)
            advance(to: target)
            // The reading holds until the next one, so no bin is left empty between them.
            let from = max((lastOnsetBin ?? target - 1) + 1, target - 4)
            for b in min(from, target)...target { envelope[b % Self.size] = max(envelope[b % Self.size], onset.strength) }
            lastOnsetBin = target
            if firstOnset == nil { firstOnset = onset.time }
            lastOnsetTime = max(lastOnsetTime, onset.time)
            recent.append(onset)
        }
        if let latest = recent.last?.time, let first = recent.first?.time, latest - first > 3.5 {
            recent.removeAll { latest - $0.time > 3.5 }
        }
    }

    /// Call every frame. Returns how hard a beat that has just happened was, compared with
    /// the beats lately (1 is typical, 2 twice as hard), or nil if there wasn't one.
    mutating func update(now: Double) -> Float? {
        advance(to: bin(now))
        if now - lastAnalysis >= 0.5 {
            lastAnalysis = now
            analyse(now: now)
        }
        // The sound has stopped: nothing is keeping time.
        if now - lastOnsetTime > 1.5 {
            period = nil
            believed = 0
        }
        return pickBeat()
    }

    // MARK: - Tempo

    private mutating func analyse(now: Double) {
        guard let firstOnset, now - firstOnset >= 3 else { return }
        let end = newest
        let begin = end - Self.window + 1
        var samples = (begin...end).map { value($0) }
        let mean = samples.reduce(0, +) / Float(samples.count)
        // Without the average, so that noise matches itself at no lag in particular. (Keeping only
        // what's above it would leave a constant that matches at every lag.)
        for i in samples.indices { samples[i] -= mean }
        let energy = samples.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else {
            confidence = 0
            period = nil
            believed = 0
            return
        }
        func autocorrelation(_ lag: Int) -> Float {
            guard lag < samples.count else { return 0 }
            var sum: Float = 0
            for i in lag..<samples.count { sum += samples[i] * samples[i - lag] }
            return sum / energy
        }
        var correlations = [Float](repeating: 0, count: Self.maxLag + 2)
        for lag in (Self.minLag - 1)...(Self.maxLag + 1) { correlations[lag] = autocorrelation(lag) }
        var bestLag = Self.minLag
        var bestScore: Float = -1
        for lag in Self.minLag...Self.maxLag {
            // A beat also matches at twice the lag, which keeps it from being passed over for
            // a lag that only matches by chance.
            let combined = correlations[lag] + 0.5 * autocorrelation(2 * lag)
            // A mild lean toward the usual middle of the range, a little over 100 beats a minute.
            let octaves = log2(Double(lag) / 28)
            let score = combined * Float(exp(-0.5 * octaves * octaves))
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        confidence = correlations[bestLag]
        if confidence < Self.dropAt {
            period = nil
            believed = 0
            return
        }
        believed = confidence >= Self.lockAt ? believed + 1 : 0
        guard period != nil || believed >= 2 else { return }

        // Between the neighbouring lags, for a period finer than one value of the envelope.
        let a = correlations[bestLag - 1], b = correlations[bestLag], c = correlations[bestLag + 1]
        let curve = a - 2 * b + c
        let shift = curve < 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / curve))) : 0
        let measured = (Double(bestLag) + shift) / Self.rate
        if let current = period, abs(measured - current) / current < 0.08 {
            // The same tempo. The beats themselves keep the period exact (see `pickBeat`); this
            // only eases it toward what the autocorrelation says.
            period = 0.95 * current + 0.05 * measured
            // If the grid has slipped off the beats, move it back.
            let best = bestComb(samples, begin: begin)
            if comb(samples, begin: begin, lastBeat: latestGridBeat(before: Double(begin + end) / Self.rate)) < 0.7 * best.score {
                anchor = best.anchor
            }
        } else {
            period = measured
            anchor = bestComb(samples, begin: begin).anchor
        }
    }

    /// The time of the latest beat on the grid at or before `time`.
    private func latestGridBeat(before time: Double) -> Double {
        guard let period else { return anchor }
        return anchor + ((time - anchor) / period).rounded(.down) * period
    }

    /// How much of the envelope's energy lies on beats spaced a period apart, walking back from
    /// the beat at `lastBeat`.
    private func comb(_ samples: [Float], begin: Int, lastBeat: Double) -> Float {
        guard let period else { return 0 }
        let lag = period * Self.rate
        var sum: Float = 0
        var t = lastBeat * Self.rate - 0.5 - Double(begin)
        while t >= 0 {
            // A beat can fall a little either side of where it's expected: take the best of
            // the neighbouring values.
            let i = Int(t.rounded())
            if i < samples.count { sum += max(samples[max(0, i - 1)], samples[min(i, samples.count - 1)], samples[min(i + 1, samples.count - 1)]) }
            t -= lag
        }
        return sum
    }

    /// The comb that catches the most of the envelope: where, in the last stretch, the beats fall.
    private func bestComb(_ samples: [Float], begin: Int) -> (score: Float, anchor: Double) {
        guard let period else { return (0, anchor) }
        let lag = period * Self.rate
        var best: (score: Float, anchor: Double) = (-1, anchor)
        let end = Double(begin + samples.count - 1)
        for offset in 0..<max(1, Int(lag.rounded())) {
            let lastBeat = (end - Double(offset) + 0.5) / Self.rate
            let score = comb(samples, begin: begin, lastBeat: lastBeat)
            if score > best.score { best = (score, lastBeat) }
        }
        return best
    }

    // MARK: - Beats

    private mutating func pickBeat() -> Float? {
        guard recent.count >= 3 else { return nil }
        defer { examined = recent[recent.count - 2].time }
        guard let period else { return nil }
        var result: Float?
        // Each onset is judged once the next has come, to see it was a peak.
        for index in 1..<(recent.count - 1) {
            let onset = recent[index]
            guard onset.time > examined else { continue }
            guard onset.strength > recent[index - 1].strength, onset.strength >= recent[index + 1].strength else { continue }

            // It has to stand out from the last second or two.
            var sum: Float = 0, squares: Float = 0
            var count: Float = 0
            for earlier in recent[0..<index] where onset.time - earlier.time <= 2 {
                sum += earlier.strength
                squares += earlier.strength * earlier.strength
                count += 1
            }
            guard count >= 20 else { continue }
            let mean = sum / count
            let deviation = max(0, squares / count - mean * mean).squareRoot()
            let threshold = max(mean + 1.2 * deviation, 1e-4)
            guard onset.strength > threshold, onset.strength > 1.5 * mean else { continue }

            // And land on the beat.
            let beats = ((onset.time - anchor) / period).rounded()
            let grid = anchor + beats * period
            let error = onset.time - grid
            guard abs(error) <= Self.tolerance * period, onset.time - lastBeat >= 0.6 * period else { continue }
            // Follow the beat: move the grid part of the way to where it really fell, and
            // set the period by how far apart the last two really were.
            let sinceLast = max(1, beats - ((lastBeat - anchor) / period).rounded())
            anchor = grid + 0.4 * error
            self.period = period + 0.08 * error / sinceLast
            lastBeat = onset.time
            let ratio = onset.strength / threshold
            let relative = typical > 0 ? ratio / typical : 1
            typical = typical > 0 ? 0.9 * typical + 0.1 * ratio : ratio
            result = max(result ?? 0, relative)
        }
        return result
    }
}
