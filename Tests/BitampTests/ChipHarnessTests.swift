import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// Runs a real song through the chiptune mode offline, for tuning it: prints how busy each
/// voice is and writes the chip version to a WAV file. Off by default; run with
/// `BITAMP_CHIP_FILE=/path/to/song.mp3 BITAMP_CHIP_OUT=/some/folder scripts/test.sh --filter ChipHarness`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_CHIP_FILE"] != nil))
struct ChipHarnessTests {
    @Test func analyzeSong() throws {
        let environment = ProcessInfo.processInfo.environment
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: environment["BITAMP_CHIP_FILE"]!))
        let seconds = Double(environment["BITAMP_CHIP_SECONDS"] ?? "60")!
        let format = file.processingFormat
        let length = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length))
        try file.read(into: buffer, frameCount: length)

        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<count { mono[i] += data[i] / Float(format.channelCount) }
        }

        let transcriber = ChipTranscriber()
        transcriber.prepare(sampleRate: format.sampleRate)
        let synth = ChipSynth()
        synth.prepare(sampleRate: format.sampleRate)
        var chip = [Float](repeating: 0, count: count)
        var frames: [ChipTranscriber.Frame] = []
        mono.withUnsafeBufferPointer { input in
            chip.withUnsafeMutableBufferPointer { output in
                var start = 0
                while start + ChipTranscriber.hop <= count {
                    transcriber.push(input.baseAddress! + start, count: ChipTranscriber.hop)
                    synth.render(into: output.baseAddress! + start, count: ChipTranscriber.hop)
                    transcriber.analyze()
                    synth.play(transcriber.frame)
                    frames.append(transcriber.frame)
                    start += ChipTranscriber.hop
                }
            }
        }

        let duration = Double(count) / format.sampleRate
        func report(_ name: String, _ voice: (ChipTranscriber.Frame) -> ChipTranscriber.Voice) {
            let notes = frames.map { voice($0).note }
            let changes = zip(notes, notes.dropFirst()).filter { $0 != $1 }.count
            let active = Double(notes.compactMap { $0 }.count) / Double(notes.count)
            let jumps = zip(notes, notes.dropFirst()).compactMap { a, b -> Int? in
                guard let a, let b, a != b else { return nil }
                return abs(a - b)
            }
            let big = jumps.filter { $0 > 7 }.count
            var lengths: [Int] = []
            var run = 1
            for (a, b) in zip(notes, notes.dropFirst()) {
                if a == b { run += 1 } else { lengths.append(run); run = 1 }
            }
            let median = lengths.isEmpty ? 0 : lengths.sorted()[lengths.count / 2]
            let changeRate = Double(changes) / duration
            let medianMs = Double(median * ChipTranscriber.hop) / format.sampleRate * 1000
            print(String(format: "CHIP %@: %.1f changes/s, active %.0f%%, jumps >7: %d of %d, median run %.0f ms",
                         name, changeRate, active * 100, big, jumps.count, medianMs))
        }
        report("lead", \.lead)
        report("harmony", \.harmony)
        report("bass", \.bass)
        let drums: [ChipTranscriber.Drum] = frames.compactMap { $0.drum?.kind }
        let kicks = drums.filter { $0 == .kick }.count
        let snares = drums.filter { $0 == .snare }.count
        let hats = drums.filter { $0 == .hat }.count
        let rate = Double(drums.count) / duration
        print(String(format: "CHIP drums: %.1f/s (kick %d, snare %d, hat %d)", rate, kicks, snares, hats))
        if let out = environment["BITAMP_CHIP_OUT"] {
            let wavFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            let url = URL(fileURLWithPath: out).appendingPathComponent("chip.wav")
            let wav = try AVAudioFile(forWriting: url, settings: wavFormat.settings)
            let outBuffer = try #require(AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: AVAudioFrameCount(count)))
            outBuffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { outBuffer.floatChannelData![0][i] = chip[i] * 0.8 }
            try wav.write(from: outBuffer)
            print("CHIP wrote \(url.path)")
        }
    }
}
