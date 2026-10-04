import Foundation

/// A small sound chip in the style of 8-bit consoles: two pulse waves, one for the lead and
/// one arpeggiating the chord, a stepped triangle for bass and a noise channel for drums,
/// each with a 4-bit volume. It plays whatever `ChipTranscriber` last heard.
///
/// Runs on the audio render thread: no allocation, no locks.
final class ChipSynth {
    /// Pulse widths, as on the classic chips: 25% for the lead, 12.5% for the thinner arpeggio.
    static let leadDuty = 0.25
    static let arpeggioDuty = 0.125
    /// How fast a voice fades after its note ends, in volume steps per second.
    static let releaseRate = 160.0
    /// How long each chord note sounds before the next, in seconds: about two hops.
    static let arpeggioStep = 0.023
    /// When the lead starts a note it goes quiet this long, in seconds, then plays at full
    /// volume and decays to `leadSustain` of it over `leadDecay` seconds, so every note,
    /// even a repeated one, is heard to begin.
    static let leadGap = 0.004
    static let leadSustain = 0.6
    static let leadDecay = 0.15

    private struct Tone {
        var phase = 0.0
        var step = 0.0
        /// 0...15. Falls one step at a time after a note ends.
        var level = 0.0
        var target = 0
    }

    private var lead = Tone()
    private var arpeggio = Tone()
    private var bass = Tone()

    // The lead's envelope: the note it plays, samples of silence left before it sounds,
    // the level it decays to and how fast.
    private var leadNote: Int?
    private var leadSilence = 0
    private var leadFloor = 0.0
    private var leadFall = 0.0

    // The arpeggio: the chord's notes as phase steps, which one is playing, and samples
    // until the next.
    private var chord = ChipTranscriber.Chord()
    private var chordSteps: (Double, Double, Double) = (0, 0, 0)
    private var chordIndex = 0
    private var untilNextStep = 0

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
        arpeggio = Tone()
        bass = Tone()
        leadNote = nil
        leadSilence = 0
        chord = ChipTranscriber.Chord()
        chordIndex = 0
        untilNextStep = 0
        noiseLevel = 0
    }

    /// Takes the notes from a new analysis.
    func play(_ frame: ChipTranscriber.Frame) {
        playLead(frame.lead, onset: frame.onset)
        playChord(frame.chord)
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

    /// Restarts the lead's envelope on a new note or an onset; otherwise follows its level.
    private func playLead(_ voice: ChipTranscriber.Voice, onset: Bool) {
        guard let note = voice.note else {
            lead.target = 0
            leadNote = nil
            return
        }
        let level = Double(voice.level)
        leadFloor = max(1, (level * Self.leadSustain).rounded())
        if onset || note != leadNote {
            lead.step = ChipTranscriber.frequency(of: note) / sampleRate
            lead.phase = 0
            lead.level = level
            leadFall = (level - leadFloor) / (Self.leadDecay * sampleRate)
            leadSilence = Int(Self.leadGap * sampleRate)
            leadNote = note
        } else {
            lead.level = max(lead.level, leadFloor)
        }
        lead.target = voice.level
    }

    /// Takes a new chord, starting its arpeggio from the bottom if it's a different one.
    private func playChord(_ next: ChipTranscriber.Chord) {
        guard next.count > 0 else {
            arpeggio.target = 0
            chord = next
            return
        }
        if !next.sameNotes(as: chord) {
            func step(_ note: Int?) -> Double {
                note.map { ChipTranscriber.frequency(of: $0) / sampleRate } ?? 0
            }
            chordSteps = (step(next.first), step(next.second), step(next.third))
            chordIndex = 0
            untilNextStep = 0
        }
        chord = next
        arpeggio.target = next.level
        arpeggio.level = Double(next.level)
    }

    /// Writes `count` samples, from -1 to 1, to `out`.
    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let release = Self.releaseRate / sampleRate
        let arpeggioSamples = max(1, Int(Self.arpeggioStep * sampleRate))
        let notes = chord.count
        for i in 0..<count {
            var sample: Float = 0

            if leadSilence > 0 {
                leadSilence -= 1
            } else {
                if lead.target > 0 && lead.level > leadFloor { lead.level = max(leadFloor, lead.level - leadFall) }
                sample += 0.26 * pulse(&lead, duty: Self.leadDuty, release: release)
            }

            if notes > 0 {
                if untilNextStep == 0 {
                    untilNextStep = arpeggioSamples
                    switch chordIndex {
                    case 0: arpeggio.step = chordSteps.0
                    case 1: arpeggio.step = chordSteps.1
                    default: arpeggio.step = chordSteps.2
                    }
                    chordIndex = (chordIndex + 1) % notes
                }
                untilNextStep -= 1
            }
            sample += 0.18 * pulse(&arpeggio, duty: Self.arpeggioDuty, release: release)
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
