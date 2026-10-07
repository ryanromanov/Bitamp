import Foundation

/// Makes music sound like 8-bit samples played back on old hardware: it holds each sample
/// for several output samples to drop the rate to `rate`, rounds it to `bits` bits, and
/// softens the shrillest of the resulting aliasing with a gentle treble cut.
///
/// Runs on the audio render thread: no allocation after `prepare`.
final class BitCrusher {
    /// Early samplers and PC sound cards played 8-bit audio at about 11 kHz.
    static let rate = 11_025.0
    static let bits = 8
    static let treble = 7_000.0
    static let maxChannels = 8

    private let levels = Float(1 << (bits - 1))
    private var step = 0.25
    private var smoothing: Float = 0.6
    // Per channel: how far through the held sample we are, the held value, and the filter.
    private var phase = [Double](repeating: 1, count: maxChannels)
    private var held = [Float](repeating: 0, count: maxChannels)
    private var filtered = [Float](repeating: 0, count: maxChannels)

    func prepare(sampleRate: Double) {
        step = min(1, Self.rate / sampleRate)
        smoothing = Float(1 - exp(-2 * Double.pi * Self.treble / sampleRate))
        for c in 0..<Self.maxChannels {
            phase[c] = 1
            held[c] = 0
            filtered[c] = 0
        }
    }

    /// The crushed version of the next sample on `channel`.
    @inline(__always)
    func process(_ sample: Float, channel: Int) -> Float {
        let c = min(channel, Self.maxChannels - 1)
        phase[c] += step
        if phase[c] >= 1 {
            phase[c] -= 1
            held[c] = (max(-1, min(1, sample)) * levels).rounded() / levels
        }
        filtered[c] += smoothing * (held[c] - filtered[c])
        return filtered[c]
    }
}
