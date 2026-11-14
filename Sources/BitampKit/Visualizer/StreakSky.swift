import Foundation

/// One star of Solar Sailing as the shader draws it: where its head and the point it was a
/// moment ago are on the picture, how far away it is and how loud its band is. Laid out like
/// `StreakStar` in the shader.
struct StreakStar {
    var head: SIMD2<Float>
    var tail: SIMD2<Float>
    /// 1 far, 0 near.
    var depth: Float
    var level: Float
    /// 1 for the far, slow, dim stars that have no streak.
    var dust: Float
    var padding: Float = 0
}

/// Works out where Solar Sailing's stars are, once a frame on the CPU, so the shader only has
/// to draw them: with hundreds of stars, every pixel working out every star was too slow in
/// full screen.
///
/// Real perspective: a star sits off to the side of the ship's path by a fixed amount (rho) and
/// is at some distance (depth, 1 far, 0 near). Where it shows on the screen is rho over depth,
/// so far stars are small and nearly still, and speed up as they come close. Each has a band of
/// the analyzer, picked at random so the sky fills evenly. Whether a star exists is decided when
/// it's born, from how loud its band was then (`history`), and it keeps that for its whole
/// flight, so quiet music makes few stars and nothing blinks.
enum StreakSky {
    /// The first of these are streaks; the rest are far, slow, dim stars.
    static let streaks = 170
    static let total = 420
    /// The analyzer history: this many buckets for each band, one for every 0.01 travelled.
    static let historySlots = 1024

    struct Frame {
        var resolution: SIMD2<Float>
        var time: Double
        var travel: Double
        var energy: Float
        var beat: Float
    }

    /// `sin` of a number, kept in 0...1.
    static func hash(_ n: Double) -> Double {
        let value = sin(n * 127.1) * 43758.5453
        return value - value.rounded(.down)
    }

    /// A hash of two whole numbers with no sines, in 0...1.
    static func hash2(_ a: Int, _ b: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: a) &* 374_761_393 &+ UInt32(truncatingIfNeeded: b) &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFFFF) / 16_777_215
    }

    /// The stars that exist now, in drawing order, written to `out`; returns how many.
    /// `history` holds `barCount * historySlots` levels, band by band.
    static func stars(_ frame: Frame, bars: [Float], history: UnsafePointer<Float>, rhoMin: Double, rhoSpan: Double,
                      into out: UnsafeMutablePointer<StreakStar>, capacity: Int) -> Int {
        let res = frame.resolution
        let width = Double(res.x), height = Double(res.y)
        let vanishing = SIMD2<Double>((width * 0.5).rounded(.down) + 0.5 + sin(frame.time * 0.31) * width * 0.07,
                                      (height * 0.5).rounded(.down) + 0.5 + cos(frame.time * 0.23) * height * 0.07)
        let roll = sin(frame.time * 0.17) * 0.7 + frame.travel * 0.04
        let k = height * 0.1
        let lag = 0.02 + 0.05 * Double(frame.energy) + 0.05 * Double(frame.beat)
        var count = 0
        for i in 0..<min(total, capacity) {
            let fi = Double(i)
            let dust = i >= streaks
            let band = min(Int(hash(fi + 41) * Double(SpectrumAnalyzer.barCount)), SpectrumAnalyzer.barCount - 1)
            let angle = hash(fi + 1) * 2 * .pi + roll
            let rho = dust ? 0.6 + 5.4 * hash(fi + 3) : rhoMin + rhoSpan * hash(fi + 3)
            let speed = dust ? 0.15 : 0.5 + 0.8 * hash(fi + 13)
            let phase = hash(fi + 29)
            let x = phase - frame.travel * speed
            let cycle = x.rounded(.down)
            let born = (phase - cycle - 1) / speed
            let bucket = Int((born * 100).rounded(.down)) & (historySlots - 1)
            let birthLevel = Double(history[band * historySlots + bucket])
            if hash2(i, Int(cycle)) > 0.15 + 1.6 * birthLevel { continue }
            let depth = 0.03 + 0.97 * pow(x - cycle, 1.5)
            let tailDepth = min(depth + (dust ? 0 : lag), 1)
            let direction = SIMD2<Double>(cos(angle), sin(angle))
            let head = vanishing + direction * (rho * k / depth)
            let tail = vanishing + direction * (rho * k / tailDepth)
            // Off the picture altogether, with room for a streak's width.
            let margin = 4.0
            if max(head.x, tail.x) < -margin || min(head.x, tail.x) > width + margin
                || max(head.y, tail.y) < -margin || min(head.y, tail.y) > height + margin { continue }
            out[count] = StreakStar(head: SIMD2(Float(head.x), Float(head.y)), tail: SIMD2(Float(tail.x), Float(tail.y)),
                                    depth: Float(depth), level: bars[band], dust: dust ? 1 : 0)
            count += 1
        }
        return count
    }
}
