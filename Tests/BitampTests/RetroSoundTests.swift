import AVFoundation
import Testing
@testable import BitampKit

@Suite struct RetroSoundTests {
    static let sampleRate = 44_100.0

    /// A tone with a few harmonics, like an instrument, as mono samples.
    static func tone(_ notes: [(note: Int, amplitude: Float)], seconds: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for (note, amplitude) in notes {
            let frequency = ChipTranscriber.frequency(of: note)
            for h in 1...4 {
                let step = 2 * Double.pi * frequency * Double(h) / sampleRate
                let level = amplitude / Float(h)
                for i in 0..<count { samples[i] += level * Float(sin(step * Double(i))) }
            }
        }
        return samples
    }

    /// A sine whose pitch wavers around `note` by `depth` semitones, `rate` times a second.
    static func vibrato(_ note: Int, depth: Double, rate: Double, seconds: Double) -> [Float] {
        var phase = 0.0
        return (0..<Int(seconds * sampleRate)).map { i in
            let pitch = Double(note) + depth * sin(2 * Double.pi * rate * Double(i) / sampleRate)
            phase += 440 * pow(2, (pitch - 69) / 12) / sampleRate
            return 0.3 * Float(sin(2 * Double.pi * phase))
        }
    }

    /// Feeds `samples` hop by hop, as the audio unit does, and returns the last frame.
    static func transcribe(_ samples: [Float]) -> ChipTranscriber.Frame {
        transcribe(left: samples, right: samples).last ?? ChipTranscriber.Frame()
    }

    /// Feeds a stereo signal hop by hop and returns every frame.
    static func transcribe(left: [Float], right: [Float]) -> [ChipTranscriber.Frame] {
        let transcriber = ChipTranscriber()
        transcriber.prepare(sampleRate: sampleRate)
        var frames: [ChipTranscriber.Frame] = []
        left.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in
                var start = 0
                while start + ChipTranscriber.hop <= left.count {
                    transcriber.push(left: left.baseAddress! + start, right: right.baseAddress! + start,
                                     count: ChipTranscriber.hop)
                    transcriber.analyze()
                    frames.append(transcriber.frame)
                    start += ChipTranscriber.hop
                }
            }
        }
        return frames
    }

    /// The hop at `seconds`.
    static func hop(at seconds: Double) -> Int { Int(seconds * sampleRate) / ChipTranscriber.hop }

    @Test func hearsTheLeadAndTheBass() {
        // A4 over A2: the lead is also the bass's fourth harmonic, so it has to survive the
        // bass's overtones being taken out.
        let frame = Self.transcribe(Self.tone([(69, 0.3), (45, 0.3)], seconds: 0.5))
        #expect(frame.lead.note == 69)
        #expect(frame.bass.note == 45)
        #expect(frame.lead.level > 0)
    }

    @Test func hearsTheCenterAsLeadAndTheSidesAsAChord() {
        // A centered C5 melody over an A minor chord panned to the sides: A3 and E4 on the
        // left, C4 on the right.
        let melody = Self.tone([(72, 0.3)], seconds: 1)
        let left = Self.tone([(57, 0.2), (64, 0.2)], seconds: 1)
        let right = Self.tone([(60, 0.2)], seconds: 1)
        let frames = Self.transcribe(left: zip(melody, left).map { $0 + $1 }, right: zip(melody, right).map { $0 + $1 })
        let frame = frames.last!
        #expect(frame.lead.note == 72)
        #expect(frame.chord.first == 57)
        #expect(frame.chord.second == 60)
        #expect(frame.chord.third == 64)
        #expect(frame.chord.level > 0)
    }

    @Test func aCenteredToneAloneHasNoChord() {
        // Nothing at the sides: the arpeggio stays quiet rather than guess.
        let frame = Self.transcribe(left: Self.tone([(72, 0.3)], seconds: 1), right: Self.tone([(72, 0.3)], seconds: 1))
        #expect(frame.last!.lead.note == 72)
        #expect(frame.last!.chord.count == 0)
    }

    @Test func vibratoStaysOnOneNote() {
        // A sung A4 wavering half a semitone either way, five and a half times a second.
        let samples = Self.vibrato(69, depth: 0.5, rate: 5.5, seconds: 2)
        let frames = Self.transcribe(left: samples, right: samples)
        let settled = frames[Self.hop(at: 0.3)...]
        #expect(settled.allSatisfy { $0.lead.note == 69 })
        #expect(settled.filter(\.onset).isEmpty)
    }

    @Test func aBriefOctaveSlipIsFoldedBackButALeapIsBelieved() {
        // A4, a 30 ms blip an octave up, A4 again, then a long A5.
        let samples = Self.tone([(69, 0.3)], seconds: 0.5) + Self.tone([(81, 0.3)], seconds: 0.03)
            + Self.tone([(69, 0.3)], seconds: 0.5) + Self.tone([(81, 0.3)], seconds: 0.6)
        let frames = Self.transcribe(left: samples, right: samples)
        let notes = frames[Self.hop(at: 0.3)..<Self.hop(at: 1.0)].map(\.lead.note)
        #expect(notes.allSatisfy { $0 == 69 })
        #expect(frames.last!.lead.note == 81)
    }

    @Test func aRepeatedNoteIsHeardAgain() {
        // The same A4 twice with a breath between: the second starts with an onset.
        let samples = Self.tone([(69, 0.3)], seconds: 0.4) + [Float](repeating: 0, count: 2_000)
            + Self.tone([(69, 0.3)], seconds: 0.4)
        let frames = Self.transcribe(left: samples, right: samples)
        let onsets = frames[Self.hop(at: 0.2)...].filter(\.onset)
        #expect(onsets.count == 1)
        #expect(onsets.allSatisfy { $0.lead.note == 69 })
    }

    @Test func silenceIsSilent() {
        let frame = Self.transcribe([Float](repeating: 0, count: 22_050))
        #expect(frame.lead.note == nil)
        #expect(frame.chord.count == 0)
        #expect(frame.bass.note == nil)
        #expect(frame.drum == nil)
    }

    @Test func aBurstAfterQuietIsADrumHit() {
        let transcriber = ChipTranscriber()
        transcriber.prepare(sampleRate: Self.sampleRate)
        var hits = 0
        // A steady quiet tone, then a hop of loud noise. The tone starting may count as a
        // hit, so only count once it has settled.
        let quiet = Self.tone([(45, 0.05)], seconds: 0.6)
        quiet.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + ChipTranscriber.hop <= buffer.count {
                transcriber.push(buffer.baseAddress! + start, count: ChipTranscriber.hop)
                transcriber.analyze()
                if start > buffer.count / 2 && transcriber.frame.drum != nil { hits += 1 }
                start += ChipTranscriber.hop
            }
        }
        #expect(hits == 0)
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<ChipTranscriber.hop).map { _ in Float.random(in: -0.8...0.8, using: &generator) }
        noise.withUnsafeBufferPointer { transcriber.push($0.baseAddress!, count: $0.count) }
        transcriber.analyze()
        #expect(transcriber.frame.drum != nil)
    }

    @Test func pulsePlaysAtThePitchOfItsNote() {
        let synth = ChipSynth()
        synth.prepare(sampleRate: Self.sampleRate)
        var frame = ChipTranscriber.Frame()
        frame.lead = .init(note: 69, level: 15)
        synth.play(frame)
        var samples = [Float](repeating: 0, count: Int(Self.sampleRate))
        samples.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        let rising = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        #expect(abs(rising - 440) <= 2)
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }

    @Test func theArpeggioCyclesThroughTheChord() {
        let synth = ChipSynth()
        synth.prepare(sampleRate: Self.sampleRate)
        var frame = ChipTranscriber.Frame()
        frame.chord = .init(first: 81, second: 93, third: nil, level: 15)
        synth.play(frame)
        let step = Int(ChipSynth.arpeggioStep * Self.sampleRate)
        var samples = [Float](repeating: 0, count: step * 6)
        samples.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        // Each step plays one note: about 20 cycles of A5, then about 40 of A6, and again.
        let cycles = (0..<6).map { i in
            let part = samples[i * step..<(i + 1) * step]
            return zip(part, part.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        }
        let expected = cycles.indices.map { $0 % 2 == 0 ? 20 : 40 }
        #expect(zip(cycles, expected).allSatisfy { abs($0 - $1) <= 2 })
    }

    @Test func anOnsetRestartsTheLead() {
        let synth = ChipSynth()
        synth.prepare(sampleRate: Self.sampleRate)
        var frame = ChipTranscriber.Frame()
        frame.lead = .init(note: 69, level: 15)
        frame.onset = true
        synth.play(frame)
        var first = [Float](repeating: 0, count: 4_410)
        first.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        // The same note again without an onset carries on; with one, it stops for a moment.
        frame.onset = false
        synth.play(frame)
        var carried = [Float](repeating: 0, count: 100)
        carried.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        frame.onset = true
        synth.play(frame)
        var restarted = [Float](repeating: 0, count: 400)
        restarted.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        #expect(first.prefix(100).allSatisfy { $0 == 0 })
        #expect(first.suffix(100).contains { $0 != 0 })
        #expect(carried.allSatisfy { $0 != 0 })
        #expect(restarted.prefix(100).allSatisfy { $0 == 0 })
        #expect(restarted.suffix(100).contains { $0 != 0 })
    }

    @Test func voicesFadeAfterTheirNoteEnds() {
        let synth = ChipSynth()
        synth.prepare(sampleRate: Self.sampleRate)
        var frame = ChipTranscriber.Frame()
        frame.bass = .init(note: 45, level: 15)
        synth.play(frame)
        synth.play(ChipTranscriber.Frame())
        var samples = [Float](repeating: 0, count: Int(Self.sampleRate / 5))
        samples.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        #expect(samples.prefix(100).contains { $0 != 0 })
        #expect(samples.suffix(100).allSatisfy { $0 == 0 })
    }

    /// Runs a tone through player → chip offline and returns the chip's output, left channel.
    @MainActor
    func render(_ sound: RetroSound) throws -> (input: [Float], output: [Float]) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let input = Self.tone([(69, 0.3), (45, 0.3)], seconds: 1)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)))
        source.frameLength = source.frameCapacity
        for channel in 0..<2 {
            for (i, sample) in input.enumerated() { source.floatChannelData![channel][i] = sample }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let chip = RetroAudioUnit.makeNode()
        engine.attach(player)
        engine.attach(chip)
        engine.connect(player, to: chip, format: format)
        engine.connect(chip, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        (chip.auAudioUnit as! RetroAudioUnit).kernel.mode = sound
        try engine.start()
        player.scheduleBuffer(source)
        player.play()

        let out = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024))
        var output: [Float] = []
        while output.count < input.count {
            let status = try engine.renderOffline(1_024, to: out)
            #expect(status == .success)
            output += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        }
        engine.stop()
        return (input, Array(output.prefix(input.count)))
    }

    @MainActor @Test func offPassesTheMusicThrough() throws {
        let (input, output) = try render(.off)
        let difference = zip(input, output).map { abs($0 - $1) }.max() ?? 1
        #expect(difference < 1e-4)
    }

    @MainActor @Test func onReplacesTheMusicWithTheChip() throws {
        let (input, output) = try render(.chiptune)
        // After the fade and the first notes, the output is the chip's square-ish waves.
        let tail = Array(output.suffix(22_050))
        #expect(tail.contains { abs($0) > 0.05 })
        let difference = zip(input.suffix(22_050), tail).map { abs($0 - $1) }.max() ?? 0
        #expect(difference > 0.1)
    }

    @MainActor @Test func crushKeepsTheSongButCoarsensIt() throws {
        let (input, output) = try render(.crush)
        let a = Array(input.suffix(22_050)), b = Array(output.suffix(22_050))
        // Still the same music: closely correlated with the input…
        let dot = zip(a, b).map { $0 * $1 }.reduce(0, +)
        let correlation = dot / (sqrt(a.map { $0 * $0 }.reduce(0, +)) * sqrt(b.map { $0 * $0 }.reduce(0, +)))
        #expect(correlation > 0.9)
        // …but not the same samples.
        #expect(zip(a, b).map { abs($0 - $1) }.max()! > 0.002)
    }

    @Test func crusherRoundsToEightBits() {
        let crusher = BitCrusher()
        crusher.prepare(sampleRate: Self.sampleRate)
        var last: Float = 0
        for _ in 0..<2_000 { last = crusher.process(0.3, channel: 0) }
        // 0.3 of 128 steps rounds to 38.
        #expect(abs(last - 38 / 128) < 1e-4)
    }
}
