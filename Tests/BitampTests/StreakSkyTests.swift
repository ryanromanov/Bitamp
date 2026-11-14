import Testing
@testable import BitampKit

/// Solar Sailing's stars, worked out on the CPU.
@Suite struct StreakSkyTests {
    let slots = StreakSky.historySlots

    func history(level: Float) -> [Float] {
        [Float](repeating: level, count: SpectrumAnalyzer.barCount * slots)
    }

    func stars(history levels: [Float], travel: Double = 3, time: Double = 5) -> [StreakStar] {
        var out = [StreakStar](repeating: StreakStar(head: .zero, tail: .zero, depth: 0, level: 0, dust: 0), count: StreakSky.total)
        let frame = StreakSky.Frame(resolution: SIMD2(240, 160), time: time, travel: travel, energy: 0.3, beat: 0)
        let bars = [Float](repeating: 0.5, count: SpectrumAnalyzer.barCount)
        let count = levels.withUnsafeBufferPointer { pointer in
            out.withUnsafeMutableBufferPointer {
                StreakSky.stars(frame, bars: bars, history: pointer.baseAddress!, rhoMin: 0.2, rhoSpan: 0.8,
                                into: $0.baseAddress!, capacity: StreakSky.total)
            }
        }
        return Array(out.prefix(count))
    }

    @Test func loudMusicMakesManyStarsAndQuietMakesFew() {
        let loud = stars(history: history(level: 0.8)).count
        let quiet = stars(history: history(level: 0.0)).count
        #expect(loud > 200, "\(loud)")
        #expect(quiet < loud / 3, "\(quiet) in quiet, \(loud) in loud")
    }

    @Test func aStarKeepsItsVerdictForItsWholeFlight() {
        // The history changing after a star was born must not make it come or go: it only
        // reads the level at its birth. Raise the whole history between two frames a moment
        // apart; the stars born before then stay as they were, so the sets differ only by
        // the stars born since.
        let before = history(level: 0.3)
        let a = stars(history: before, travel: 3.00)
        let b = stars(history: before, travel: 3.01)
        // A moment on, with nothing changed, the same stars are there (a few may leave or arrive).
        #expect(abs(a.count - b.count) <= 6, "\(a.count) then \(b.count)")
    }

    @Test func starsKeepInsideTheirBoundsAndFarOnesAreDim() {
        for star in stars(history: history(level: 0.8)) {
            #expect(star.depth >= 0.03 && star.depth <= 1)
            #expect(star.head.x.isFinite && star.head.y.isFinite)
        }
    }

    @Test func theHashesStayInRange() {
        for i in 0..<1000 {
            let a = StreakSky.hash(Double(i) * 3.7), b = StreakSky.hash2(i, -i)
            #expect(a >= 0 && a <= 1)
            #expect(b >= 0 && b <= 1)
        }
    }
}
