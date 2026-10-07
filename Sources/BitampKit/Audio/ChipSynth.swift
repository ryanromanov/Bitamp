import Foundation

/// A small sound chip in the style of 8-bit consoles: two pulse waves for lead and harmony,
/// a stepped triangle for bass and a noise channel for drums, each with a 4-bit volume.
/// It plays a `ChipScore`'s moments (the lead and bass on their channels, the chord as a
/// fast arpeggio on the harmony channel), or whatever `ChipTranscriber` last heard.
///
/// Runs on the audio render thread: no allocation, no locks.
final class ChipSynth {
    /// Pulse widths, as on the classic chips: 25% for the lead, 12.5% for the thinner harmony.
    static let leadDuty = 0.25
    static let harmonyDuty = 0.125
    /// How fast a voice fades after its note ends, in volume steps per second.
    static let releaseRate = 160.0
    /// After a note starts, its volume falls this fast to `sustainShare` of where it began,
    /// so repeated notes are heard as new ones.
    static let decayRate = 25.0
    static let sustainShare = 0.6
    /// How long a sounding voice goes quiet when it's struck again, for a crisp attack.
    static let retriggerGap = 0.003
    /// How long the arpeggio stays on each chord note.
    static let arpeggioStep = 0.023

    private struct Tone {
        var phase = 0.0
        var step = 0.0
        /// 0...15. Falls one step at a time after a note ends.
        var level = 0.0
        var target = 0
        /// Where the volume settles after a note starts.
        var sustain = 0.0
        /// Samples of silence left before a retriggered note sounds.
        var gap = 0
    }

    private var lead = Tone()
    private var harmony = Tone()
    private var bass = Tone()

    // The arpeggio: the chord's notes as phase steps, and which one is playing for how long.
    private var chordSteps: (Double, Double, Double) = (0, 0, 0)
    private var chordCount = 0
    private var arpeggioIndex = 0
    private var arpeggioLeft = 0

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
        chordCount = 0
    }

    /// Takes the notes from a new analysis.
    func play(_ frame: ChipTranscriber.Frame) {
        set(&lead, frame.lead)
        set(&harmony, frame.harmony)
        set(&bass, frame.bass)
        chordCount = 0
        if let drum = frame.drum { hit(drum) }
    }

    /// Starts a drum hit: low, slow noise for the kick, a mid crash for the snare, a short
    /// hiss for hats.
    func hit(_ drum: (kind: ChipTranscriber.Drum, level: Int)) {
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

    private func set(_ tone: inout Tone, _ voice: ChipTranscriber.Voice) {
        if let note = voice.note {
            tone.step = ChipTranscriber.frequency(of: note) / sampleRate
            tone.target = voice.level
            tone.level = Double(voice.level)
            tone.sustain = tone.level
        } else {
            tone.target = 0
        }
    }

    /// Takes the notes of a moment of a `ChipScore`.
    func play(_ moment: ChipMoment) {
        strike(&lead, note: moment.lead, level: moment.leadLevel, onset: moment.onsets & ChipMoment.leadOnset != 0)
        strike(&bass, note: moment.bass, level: moment.bassLevel, onset: moment.onsets & ChipMoment.bassOnset != 0)

        let (a, b, c) = moment.chord
        let steps = (a == 0 ? 0 : step(of: a), b == 0 ? 0 : step(of: b), c == 0 ? 0 : step(of: c))
        let count = a == 0 ? 0 : b == 0 ? 1 : c == 0 ? 2 : 3
        let onset = moment.onsets & ChipMoment.chordOnset != 0
        if onset || count != chordCount || steps != chordSteps {
            arpeggioIndex = 0
            arpeggioLeft = 0
        }
        chordSteps = steps
        chordCount = count
        // While arpeggiating, `render` picks the harmony's note.
        strike(&harmony, note: a, level: moment.chordLevel, onset: onset, step: count > 1 ? harmony.step : steps.0)
    }

    private func step(of note: UInt8) -> Double {
        ChipTranscriber.frequency(of: Int(note)) / sampleRate
    }

    /// Sets a voice to a score note. A new note, or the same one struck again, starts at
    /// full volume and falls to its sustain; a held note just follows the level.
    private func strike(_ tone: inout Tone, note: UInt8, level: UInt8, onset: Bool, step: Double? = nil) {
        guard note != 0, level > 0 else {
            tone.target = 0
            return
        }
        let step = step ?? self.step(of: note)
        let sounding = tone.target > 0
        let attack = onset || !sounding || (step != tone.step && chordCount <= 1)
        tone.step = step
        tone.target = Int(level)
        tone.sustain = max(1, Double(level) * Self.sustainShare)
        if attack {
            if sounding && onset { tone.gap = Int(Self.retriggerGap * sampleRate) }
            tone.level = Double(level)
        } else {
            tone.level = min(tone.level, Double(level))
        }
    }

    /// Writes `count` samples, from -1 to 1, to `out`.
    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let release = Self.releaseRate / sampleRate
        let decay = Self.decayRate / sampleRate
        let arpeggioSamples = Int(Self.arpeggioStep * sampleRate)
        for i in 0..<count {
            var sample: Float = 0

            if chordCount > 1 {
                if arpeggioLeft <= 0 {
                    arpeggioLeft = arpeggioSamples
                    harmony.step = arpeggioIndex == 0 ? chordSteps.0 : arpeggioIndex == 1 ? chordSteps.1 : chordSteps.2
                    arpeggioIndex = (arpeggioIndex + 1) % chordCount
                }
                arpeggioLeft -= 1
            }

            sample += 0.26 * pulse(&lead, duty: Self.leadDuty, release: release, decay: decay)
            sample += 0.18 * pulse(&harmony, duty: Self.harmonyDuty, release: release, decay: decay)
            sample += 0.34 * triangle(&bass, release: release, decay: decay)

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

    private func advance(_ tone: inout Tone, release: Double, decay: Double) -> Float? {
        if tone.target == 0 {
            tone.level = max(0, tone.level - release)
        } else if tone.level > tone.sustain {
            tone.level = max(tone.sustain, tone.level - decay)
        }
        guard tone.level > 0 else { return nil }
        if tone.gap > 0 {
            tone.gap -= 1
            return nil
        }
        tone.phase += tone.step
        if tone.phase >= 1 { tone.phase -= 1 }
        // Whole volume steps only, like a 4-bit volume register.
        return Float(tone.level.rounded(.up)) / 15
    }

    private func pulse(_ tone: inout Tone, duty: Double, release: Double, decay: Double) -> Float {
        guard let volume = advance(&tone, release: release, decay: decay) else { return 0 }
        return (tone.phase < duty ? 1 : -1) * volume
    }

    /// A 32-step triangle, the staircase shape of the classic bass channel.
    private func triangle(_ tone: inout Tone, release: Double, decay: Double) -> Float {
        guard let volume = advance(&tone, release: release, decay: decay) else { return 0 }
        let step = Int(tone.phase * 32)
        let height = step < 16 ? 15 - step : step - 16
        return (Float(height) / 7.5 - 1) * volume
    }
}
