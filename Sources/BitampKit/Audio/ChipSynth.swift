import Foundation

/// A small sound chip in the style of 8-bit consoles: two pulse waves for lead and harmony,
/// a stepped triangle for bass and a noise channel for drums, each with a 4-bit volume.
/// It plays whatever `ChipTranscriber` last heard.
///
/// Runs on the audio render thread: no allocation, no locks.
final class ChipSynth {
    /// Pulse widths, as on the classic chips: 25% for the lead, 12.5% for the thinner harmony.
    static let leadDuty = 0.25
    static let harmonyDuty = 0.125
    /// How fast a voice fades after its note ends, in volume steps per second.
    static let releaseRate = 160.0

    private struct Tone {
        var phase = 0.0
        var step = 0.0
        /// 0...15. Falls one step at a time after a note ends.
        var level = 0.0
        var target = 0
    }

    private var lead = Tone()
    private var harmony = Tone()
    private var bass = Tone()

    /// A 15-bit shift register, like the noise channel's, clocked at `noiseClock` Hz.
    private var lfsr: UInt16 = 1
    private var noisePhase = 0.0
    private var noiseStep = 0.0
    private var noiseLevel = 0.0
    private var noiseDecay = 0.0
    private var noiseOut: Float = 1

    private var sampleRate = 44_100.0

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        lead = Tone()
        harmony = Tone()
        bass = Tone()
        noiseLevel = 0
    }

    /// Takes the notes from a new analysis.
    func play(_ frame: ChipTranscriber.Frame) {
        set(&lead, frame.lead)
        set(&harmony, frame.harmony)
        set(&bass, frame.bass)
        if let drum = frame.drum {
            // Low, slow noise for the kick, a mid crash for the snare, a short hiss for hats.
            let (clock, seconds, scale): (Double, Double, Double)
            switch drum.kind {
            case .kick: (clock, seconds, scale) = (1_800, 0.09, 1)
            case .snare: (clock, seconds, scale) = (11_000, 0.12, 0.8)
            case .hat: (clock, seconds, scale) = (sampleRate, 0.035, 0.5)
            }
            noiseStep = min(clock, sampleRate) / sampleRate
            noiseLevel = (Double(drum.level) * scale).rounded()
            noiseDecay = noiseLevel / (seconds * sampleRate)
        }
    }

    private func set(_ tone: inout Tone, _ voice: ChipTranscriber.Voice) {
        if let note = voice.note {
            tone.step = ChipTranscriber.frequency(of: note) / sampleRate
            tone.target = voice.level
            tone.level = Double(voice.level)
        } else {
            tone.target = 0
        }
    }

    /// Writes `count` samples, from -1 to 1, to `out`.
    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let release = Self.releaseRate / sampleRate
        for i in 0..<count {
            var sample: Float = 0

            sample += 0.26 * pulse(&lead, duty: Self.leadDuty, release: release)
            sample += 0.18 * pulse(&harmony, duty: Self.harmonyDuty, release: release)
            sample += 0.34 * triangle(&bass, release: release)

            if noiseLevel > 0 {
                noisePhase += noiseStep
                while noisePhase >= 1 {
                    noisePhase -= 1
                    let bit = (lfsr ^ (lfsr >> 1)) & 1
                    lfsr = (lfsr >> 1) | (bit << 14)
                    noiseOut = lfsr & 1 == 0 ? 1 : -1
                }
                sample += 0.22 * noiseOut * Float(noiseLevel.rounded(.up)) / 15
                noiseLevel = max(0, noiseLevel - noiseDecay)
            }
            out[i] = sample
        }
    }

    private func advance(_ tone: inout Tone, release: Double) -> Float? {
        if tone.target == 0 { tone.level = max(0, tone.level - release) }
        guard tone.level > 0 else { return nil }
        tone.phase += tone.step
        if tone.phase >= 1 { tone.phase -= 1 }
        // Whole volume steps only, like a 4-bit volume register.
        return Float(tone.level.rounded(.up)) / 15
    }

    private func pulse(_ tone: inout Tone, duty: Double, release: Double) -> Float {
        guard let volume = advance(&tone, release: release) else { return 0 }
        return (tone.phase < duty ? 1 : -1) * volume
    }

    /// A 32-step triangle, the staircase shape of the classic bass channel.
    private func triangle(_ tone: inout Tone, release: Double) -> Float {
        guard let volume = advance(&tone, release: release) else { return 0 }
        let step = Int(tone.phase * 32)
        let height = step < 16 ? 15 - step : step - 16
        return (Float(height) / 7.5 - 1) * volume
    }
}
