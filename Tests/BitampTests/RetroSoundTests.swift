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

    /// Feeds `samples` hop by hop, as the audio unit does, and returns the last frame.
    static func transcribe(_ samples: [Float]) -> ChipTranscriber.Frame {
        let transcriber = ChipTranscriber()
        transcriber.prepare(sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + ChipTranscriber.hop <= buffer.count {
                transcriber.push(buffer.baseAddress! + start, count: ChipTranscriber.hop)
                transcriber.analyze()
                start += ChipTranscriber.hop
            }
        }
        return transcriber.frame
    }

    @Test func hearsTheLeadAndTheBass() {
        // A4 over A2: the lead is also the bass's fourth harmonic, so it has to survive the
        // bass's overtones being taken out.
        let frame = Self.transcribe(Self.tone([(69, 0.3), (45, 0.3)], seconds: 0.5))
        #expect(frame.lead.note == 69)
        #expect(frame.bass.note == 45)
        #expect(frame.lead.level > 0)
    }

    @Test func hearsAChordAsLeadAndHarmony() {
        // C5 and E5 over C3.
        let frame = Self.transcribe(Self.tone([(72, 0.3), (76, 0.25), (48, 0.3)], seconds: 0.5))
        #expect(Set([frame.lead.note, frame.harmony.note]) == [72, 76])
        #expect(frame.bass.note == 48)
    }

    @Test func silenceIsSilent() {
        let frame = Self.transcribe([Float](repeating: 0, count: 22_050))
        #expect(frame.lead.note == nil)
        #expect(frame.harmony.note == nil)
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
    func render(_ sound: RetroSound, blend: Float = 0) throws -> (input: [Float], output: [Float]) {
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
        (chip.auAudioUnit as! RetroAudioUnit).kernel.blend = blend
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

    @MainActor @Test func blendKeepsSomeOfTheSongUnderTheChip() throws {
        let (input, chipOnly) = try render(.chiptune)
        let (_, blended) = try render(.chiptune, blend: ChipBlend.medium.level)
        // Once faded in, the blend adds exactly 40% of the music to the same chip.
        let tail = 22_050
        let error = zip(zip(blended.suffix(tail), chipOnly.suffix(tail)), input.suffix(tail))
            .map { abs($0.0 - $0.1 - 0.4 * $1) }.max() ?? 1
        #expect(error < 1e-3)
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
