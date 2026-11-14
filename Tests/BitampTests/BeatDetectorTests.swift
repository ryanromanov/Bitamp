import Testing
@testable import BitampKit

/// The visualizer's beat finder: it should follow kick drums, not a sustained bass or the
/// singing over it.
@Suite struct BeatDetectorTests {
    let frame = 1.0 / 30

    func bars(bass: Float, vocal: [Float] = []) -> [Float] {
        var bars = [Float](repeating: 0.05, count: SpectrumAnalyzer.barCount)
        for i in 0..<BeatDetector.lowBars { bars[i] = bass }
        for (i, level) in vocal.enumerated() where i + 5 < bars.count { bars[i + 5] = level }
        return bars
    }

    @Test func aKickEveryHalfSecondIsFound() {
        var detector = BeatDetector()
        var level: Float = 0.1
        var found = 0
        for step in 0..<(30 * 10) {
            if step % 15 == 0 { level = 0.9 } else { level = max(0.1, level - 0.08) }
            if detector.update(bars: bars(bass: level), at: Double(step) * frame) != nil { found += 1 }
        }
        #expect(found >= 18, "20 kicks in ten seconds, found \(found)")
        #expect(found <= 20)
    }

    @Test func aSustainedBassIsNotABeat() {
        var detector = BeatDetector()
        var found = 0
        for step in 0..<(30 * 10) {
            // Loud, steady bass; the level wobbles a little as real bass does.
            let wobble: Float = step % 2 == 0 ? 0.01 : -0.01
            if detector.update(bars: bars(bass: 0.8 + wobble), at: Double(step) * frame) != nil { found += 1 }
        }
        #expect(found <= 1, "only the first sound can count, found \(found)")
    }

    @Test func singingOverASteadyBassIsNotABeat() {
        var detector = BeatDetector()
        var found = 0
        var generator = SystemRandomNumberGenerator()
        for step in 0..<(30 * 10) {
            let vocal = (0..<8).map { _ in Float.random(in: 0.2...0.9, using: &generator) }
            if detector.update(bars: bars(bass: 0.6, vocal: vocal), at: Double(step) * frame) != nil { found += 1 }
        }
        #expect(found <= 1, "found \(found)")
    }

    @Test func twoRisesWithinTheCooldownAreOneBeat() {
        var detector = BeatDetector()
        _ = detector.update(bars: bars(bass: 0.1), at: 0)
        #expect(detector.update(bars: bars(bass: 0.9), at: 1) != nil)
        _ = detector.update(bars: bars(bass: 0.1), at: 1.03)
        #expect(detector.update(bars: bars(bass: 0.9), at: 1.1) == nil)
    }

    @Test func unchangedBarsAreNotAnotherLook() {
        var detector = BeatDetector()
        let same = bars(bass: 0.7)
        _ = detector.update(bars: same, at: 0)
        #expect(detector.update(bars: same, at: 0.05) == nil)
    }

    @Test func aHardKickIsStrongerThanASoftOne() throws {
        var detector = BeatDetector()
        var strengths: [Int: Float] = [:]
        var level: Float = 0.1
        for step in 0..<(30 * 6) {
            // Steady soft kicks, and one hard one at step 150.
            let kick: Float = step == 150 ? 1.0 : 0.5
            if step % 15 == 0 { level = kick } else { level = max(0.1, level - 0.08) }
            if let strength = detector.update(bars: bars(bass: level), at: Double(step) * frame) { strengths[step] = strength }
        }
        let hard = try #require(strengths[150])
        let soft = try #require(strengths[135])
        #expect(hard > soft)
    }
}
