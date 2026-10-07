import AVFoundation
import Testing
@testable import BitampKit

@Suite struct RetroSoundTests {
    static let sampleRate = 44_100.0

    /// A tone with a few harmonics, like an instrument, as mono samples.
    static func tone(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for h in 1...4 {
            let step = 2 * Double.pi * frequency * Double(h) / sampleRate
            let level = amplitude / Float(h)
            for i in 0..<count { samples[i] += level * Float(sin(step * Double(i))) }
        }
        return samples
    }

    /// Runs a tone through player → retro sound offline and returns its output, left channel.
    @MainActor
    func render(_ sound: RetroSound) throws -> (input: [Float], output: [Float]) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let input = zip(Self.tone(frequency: 440, amplitude: 0.3, seconds: 1), Self.tone(frequency: 110, amplitude: 0.3, seconds: 1))
            .map { $0 + $1 }
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)))
        source.frameLength = source.frameCapacity
        for channel in 0..<2 {
            for (i, sample) in input.enumerated() { source.floatChannelData![channel][i] = sample }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let retro = RetroAudioUnit.makeNode()
        engine.attach(player)
        engine.attach(retro)
        engine.connect(player, to: retro, format: format)
        engine.connect(retro, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        (retro.auAudioUnit as! RetroAudioUnit).kernel.mode = sound
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
