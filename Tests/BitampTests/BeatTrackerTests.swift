import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// The beat tracker, on made-up onsets the way the analyzer makes them: one a hop of 2048
/// samples (46 ms), a little noise throughout, and kicks, piano notes or neither.
@Suite struct BeatTrackerTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static let hop = 2048.0 / 44100

    /// Runs the tracker over `seconds`, with `kicks` (times of hard hits) and `notes` (times of
    /// softer hits that aren't on the beat); returns the times and hardness of the beats found.
    func run(seconds: Double, kicks: [Double], notes: [Double] = [], noteStrength: Float = 0.45, kickStrength: Float = 0.6,
             seed: UInt64 = 1) -> [(time: Double, relative: Float)] {
        var generator = Generator(state: seed)
        var tracker = BeatTracker()
        var found: [(Double, Float)] = []
        let start = 1000.0  // Uptime is never near zero.
        var t = 0.0
        while t < seconds {
            var strength = Float.random(in: 0.03...0.08, using: &generator)
            // A hit lands in the hop that contains it.
            for kick in kicks where kick >= t && kick < t + Self.hop { strength += kickStrength }
            for note in notes where note >= t && note < t + Self.hop { strength += noteStrength }
            tracker.add([Onset(time: start + t, strength: strength)])
            if let relative = tracker.update(now: start + t) { found.append((t, relative)) }
            t += Self.hop
        }
        return found
    }

    func steady(bpm: Double, seconds: Double) -> [Double] {
        let period = 60 / bpm
        return stride(from: 0.2, to: seconds, by: period).map { $0 }
    }

    @Test func aSteadyBeatIsFoundOnTheBeat() {
        for bpm in [90.0, 120, 140] {
            let kicks = steady(bpm: bpm, seconds: 30)
            let found = run(seconds: 30, kicks: kicks)
            let after = found.filter { $0.time > 10 }
            let expected = kicks.filter { $0 > 10 }.count
            #expect(after.count >= expected * 7 / 10, "\(bpm) BPM: found \(after.count) of \(expected)")
            #expect(after.count <= expected + 1, "\(bpm) BPM: found \(after.count), \(expected) kicks")
            // Each one is within a hop or two of a real kick.
            let onKick = after.filter { beat in kicks.contains { abs($0 - beat.time) < 0.1 } }.count
            #expect(onKick >= after.count * 9 / 10, "\(bpm) BPM: \(onKick) of \(after.count) on a kick")
        }
    }

    @Test func pianoNotesBetweenTheBeatsDoNotCount() {
        var generator = Generator(state: 7)
        let kicks = steady(bpm: 120, seconds: 30)
        // Three notes a second at random times: more than the kicks.
        let notes = (0..<90).map { _ in Double.random(in: 0..<30, using: &generator) }
        let found = run(seconds: 30, kicks: kicks, notes: notes)
        let after = found.filter { $0.time > 10 }
        let onKick = after.filter { beat in kicks.contains { abs($0 - beat.time) < 0.1 } }.count
        #expect(onKick >= after.count * 7 / 10, "\(onKick) of \(after.count) beats were on a kick")
        #expect(after.count >= 20, "only \(after.count)")
    }

    @Test func pianoAsLoudAsTheKicksStillDoesNotFireOffTheBeat() {
        var generator = Generator(state: 11)
        let kicks = steady(bpm: 120, seconds: 40)
        // Notes exactly as hard as the kicks, 2 or 3 a second, anywhere: the beat may be missed
        // sometimes, but nothing off it should count.
        let notes = (0..<90).map { _ in Double.random(in: 0..<40, using: &generator) }
        let found = run(seconds: 40, kicks: kicks, notes: notes, noteStrength: 0.6).filter { $0.time > 10 }
        let onKick = found.filter { beat in kicks.contains { abs($0 - beat.time) < 0.1 } }.count
        #expect(onKick >= found.count * 9 / 10, "\(onKick) of \(found.count) on a kick")
        #expect(found.count >= 20, "only \(found.count)")
    }

    @Test func noSteadyBeatMeansNoPulses() {
        var generator = Generator(state: 3)
        // Hits at random times, as loud as kicks.
        let hits = (0..<60).map { _ in Double.random(in: 0..<30, using: &generator) }.sorted()
        let found = run(seconds: 30, kicks: hits)
        #expect(found.count <= 8, "found \(found.count) beats in noise")
    }

    @Test func nothingButNoiseMeansNoPulses() {
        #expect(run(seconds: 20, kicks: []).isEmpty)
    }

    @Test func itFollowsATempoChange() {
        let slow = steady(bpm: 100, seconds: 20)
        let fast = steady(bpm: 140, seconds: 40).map { $0 + 20 }.filter { $0 < 40 }
        let found = run(seconds: 40, kicks: slow + fast)
        let late = found.filter { $0.time > 30 }
        let onKick = late.filter { beat in fast.contains { abs($0 - beat.time) < 0.1 } }.count
        #expect(late.count >= 8, "found \(late.count) after the change")
        #expect(onKick >= late.count * 7 / 10, "\(onKick) of \(late.count) on a kick")
    }

    @Test func aHarderHitIsCalledHarder() throws {
        var kicks = steady(bpm: 120, seconds: 24)
        let hard = try #require(kicks.first { $0 > 16 })
        kicks.removeAll { $0 == hard }
        // Two kicks' worth of strength, in place of the one at `hard`.
        let found = run(seconds: 24, kicks: kicks, notes: [hard], noteStrength: 1.3)
        let beat = try #require(found.first { abs($0.time - hard) < 0.12 })
        #expect(beat.relative > 1.3, "\(beat.relative)")
    }

    @Test func aTrackerThatHasBeenToldNothingGivesNothing() {
        var tracker = BeatTracker()
        #expect(tracker.update(now: 1000) == nil)
        #expect(!tracker.locked)
    }
}

/// The whole path, from sound to beats: made-up audio through the real analyzer.
@Suite struct BeatTrackingFromAudioTests {
    static let sampleRate = 44_100.0

    /// Ten seconds in, a drum loop at 120 BPM (a low thump and a click on every beat) under
    /// piano-like notes: decaying tones with overtones, at random times and pitches.
    func song(seconds: Double, piano: Bool, seed: UInt64, pianoLevel: Double = 0.12) -> (samples: [Float], kicks: [Double]) {
        var generator = BeatTrackerTests.Generator(state: seed)
        let count = Int(seconds * Self.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let kicks = stride(from: 0.3, to: seconds, by: 0.5).map { $0 }
        for kick in kicks {
            let start = Int(kick * Self.sampleRate)
            for i in 0..<min(Int(0.25 * Self.sampleRate), count - start) {
                let t = Double(i) / Self.sampleRate
                let thump = sin(2 * .pi * (55 + 90 * exp(-t * 40)) * t) * exp(-t * 14)
                let click = i < 200 ? Double.random(in: -1...1, using: &generator) * exp(-t * 600) : 0
                samples[start + i] += Float(0.7 * thump + 0.3 * click)
            }
        }
        if piano {
            for _ in 0..<Int(seconds * 3) {
                let start = Int(Double.random(in: 0..<(seconds - 1), using: &generator) * Self.sampleRate)
                let pitch = 110 * pow(2, Double.random(in: 0...3, using: &generator))
                for i in 0..<min(Int(0.8 * Self.sampleRate), count - start) {
                    let t = Double(i) / Self.sampleRate
                    var tone = 0.0
                    for harmonic in 1...5 { tone += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic) }
                    samples[start + i] += Float(pianoLevel * tone * exp(-t * 4))
                }
            }
        }
        return (samples, kicks)
    }

    func beats(in samples: [Float], chunk: Int = 2048) -> [Double] {
        let analyzer = SpectrumAnalyzer()
        analyzer.sampleRate = Self.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        var tracker = BeatTracker()
        var found: [Double] = []
        let start = 5000.0
        var offset = 0
        while offset + chunk <= samples.count {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            buffer.frameLength = AVAudioFrameCount(chunk)
            for i in 0..<chunk { buffer.floatChannelData![0][i] = samples[offset + i] }
            // Heard at the end of the buffer, as the tap hands it over.
            let time = start + Double(offset + chunk) / Self.sampleRate
            analyzer.process(buffer, at: time)
            tracker.add(analyzer.drainOnsets())
            if tracker.update(now: time) != nil { found.append(time - start) }
            offset += chunk
        }
        return found
    }

    @Test func aDrumLoopIsFound() {
        let (samples, kicks) = song(seconds: 30, piano: false, seed: 5)
        let found = beats(in: samples).filter { $0 > 10 }
        // The hit is somewhere in the buffer that ends at the time reported.
        let onKick = found.filter { beat in kicks.contains { beat - $0 > -0.02 && beat - $0 < 0.12 } }.count
        #expect(found.count >= 25, "found \(found.count)")
        #expect(onKick >= found.count * 9 / 10, "\(onKick) of \(found.count) on a kick")
    }

    @Test func aDrumLoopUnderPianoIsFoundAndThePianoIsNot() {
        let (samples, kicks) = song(seconds: 30, piano: true, seed: 5)
        let found = beats(in: samples).filter { $0 > 10 }
        let onKick = found.filter { beat in kicks.contains { beat - $0 > -0.02 && beat - $0 < 0.12 } }.count
        #expect(found.count >= 15, "found \(found.count)")
        #expect(onKick >= found.count * 8 / 10, "\(onKick) of \(found.count) on a kick")
    }

    @Test func pianoAsLoudAsTheDrumsMayMissBeatsButDoesNotFireOffThem() {
        let (samples, kicks) = song(seconds: 40, piano: true, seed: 5, pianoLevel: 0.25)
        let found = beats(in: samples).filter { $0 > 10 }
        let onKick = found.filter { beat in kicks.contains { beat - $0 > -0.02 && beat - $0 < 0.12 } }.count
        #expect(onKick >= found.count * 7 / 10, "\(onKick) of \(found.count) on a kick")
    }

    @Test func pianoAloneGivesNoPulses() {
        var samples = song(seconds: 30, piano: true, seed: 9).samples
        // Take the drums back out: only what the piano added is left.
        let drums = song(seconds: 30, piano: false, seed: 9).samples
        for i in samples.indices { samples[i] -= drums[i] }
        let found = beats(in: samples)
        #expect(found.count <= 10, "found \(found.count) beats in piano alone")
    }

    /// A band: kick on 1 and 3, snare on 2 and 4, hi-hats on the eighths, a bass note on every
    /// beat and a held chord, each hit a little off in time and in loudness. Returns the times
    /// of the quarter notes.
    func band(seconds: Double, bpm: Double, seed: UInt64) -> (samples: [Float], beats: [Double]) {
        var generator = BeatTrackerTests.Generator(state: seed)
        let count = Int(seconds * Self.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let quarter = 60 / bpm
        var beats: [Double] = []
        func add(at time: Double, length: Double, _ sound: (Double) -> Double, level: Double) {
            let start = Int(time * Self.sampleRate)
            guard start >= 0, start < count else { return }
            let jitter = Double.random(in: 0.8...1.2, using: &generator)
            for i in 0..<min(Int(length * Self.sampleRate), count - start) {
                samples[start + i] += Float(level * jitter * sound(Double(i) / Self.sampleRate))
            }
        }
        var noise = BeatTrackerTests.Generator(state: seed &+ 99)
        var n = 0
        var time = 0.3
        while time < seconds - 0.5 {
            beats.append(time)
            let wobble = Double.random(in: -0.008...0.008, using: &generator)
            if n % 2 == 0 {
                add(at: time + wobble, length: 0.25, { sin(2 * .pi * (55 + 90 * exp(-$0 * 40)) * $0) * exp(-$0 * 14) }, level: 0.7)
            } else {
                add(at: time + wobble, length: 0.2, { _ in Double.random(in: -1...1, using: &noise) * 0.6 }, level: 0.5)
            }
            add(at: time, length: 0.4, { sin(2 * .pi * 82 * $0) * exp(-$0 * 5) }, level: 0.25)
            for offset in [0.0, quarter / 2] {
                add(at: time + offset, length: 0.05, { Double.random(in: -1...1, using: &noise) * exp(-$0 * 80) }, level: 0.12)
            }
            time += quarter
            n += 1
        }
        for i in 0..<count {
            let t = Double(i) / Self.sampleRate
            samples[i] += Float(0.06 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)))
        }
        return (samples, beats)
    }

    /// The tap hands over about 100 ms of sound at a time, not 46.
    @Test func aBandIsFoundFromHundredMillisecondBuffers() {
        for bpm in [96.0, 120] {
            let (samples, quarters) = band(seconds: 40, bpm: bpm, seed: 33)
            let found = beats(in: samples, chunk: 4410).filter { $0 > 10 }
            let onBeat = found.filter { beat in quarters.contains { beat - $0 > -0.03 && beat - $0 < 0.17 } }.count
            let expected = quarters.filter { $0 > 10 }.count
            #expect(found.count >= expected / 2, "\(bpm) BPM: found \(found.count) of \(expected) beats")
            #expect(onBeat >= found.count * 9 / 10, "\(bpm) BPM: \(onBeat) of \(found.count) on a beat")
        }
    }

    @Test func drumsUnderPianoAreFoundFromHundredMillisecondBuffers() {
        let (samples, kicks) = song(seconds: 40, piano: true, seed: 5)
        let found = beats(in: samples, chunk: 4410).filter { $0 > 10 }
        let onKick = found.filter { beat in kicks.contains { beat - $0 > -0.03 && beat - $0 < 0.17 } }.count
        #expect(found.count >= 15, "found \(found.count)")
        #expect(onKick >= found.count * 8 / 10, "\(onKick) of \(found.count) on a kick")
    }

    /// How soon the pulses start once the beat does.
    @Test func theBeatIsFoundWithinTwoSecondsOfStarting() {
        for chunk in [2048, 4410] {
            for bpm in [100.0, 128] {
                var (samples, quarters) = band(seconds: 30, bpm: bpm, seed: 41)
                // A quiet pad for the first 8 seconds, then the band comes in.
                let entry = 8.0
                for i in 0..<Int(entry * Self.sampleRate) where i < samples.count {
                    samples[i] = 0.02 * sin(2 * .pi * 220 * Float(i) / Float(Self.sampleRate))
                }
                quarters = quarters.filter { $0 >= entry }
                let found = beats(in: samples, chunk: chunk).filter { $0 >= entry }
                let first = found.first.map { $0 - entry }
                #expect(first != nil && first! <= 2.0, "\(bpm) BPM, \(chunk)-sample buffers: first beat \(first.map { String(format: "%.1f s", $0) } ?? "never") after the band came in")
            }
        }
    }

    @Test func aBandsBackbeatIsFoundOnTheQuarterNotes() {
        for bpm in [96.0, 120, 150] {
            let (samples, quarters) = band(seconds: 40, bpm: bpm, seed: 21)
            let found = beats(in: samples).filter { $0 > 10 }
            let onBeat = found.filter { beat in quarters.contains { beat - $0 > -0.03 && beat - $0 < 0.13 } }.count
            let expected = quarters.filter { $0 > 10 }.count
            // Fast music may be followed at half speed, on the kicks: still on the beat.
            #expect(found.count >= expected / (bpm > 140 ? 4 : 2), "\(bpm) BPM: found \(found.count) of \(expected) beats")
            #expect(onBeat >= found.count * 9 / 10, "\(bpm) BPM: \(onBeat) of \(found.count) on a beat")
        }
    }
}
