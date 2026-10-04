import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// Runs a real song through the chiptune mode offline, for tuning it: prints how busy each
/// voice is and writes the chip version to a WAV file. Off by default; run with
/// `BITAMP_CHIP_FILE=/path/to/song.mp3 BITAMP_CHIP_OUT=/some/folder scripts/test.sh --filter ChipHarness`.
/// `BITAMP_CHIP_START` and `BITAMP_CHIP_SECONDS` pick the excerpt, in seconds (default 0 and
/// 60), `BITAMP_CHIP_NAME` names the WAV (default `chip.wav`), and `BITAMP_CHIP_TRACE=1`
/// prints what was heard on every hop.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_CHIP_FILE"] != nil))
struct ChipHarnessTests {
    @Test func analyzeSong() throws {
        let environment = ProcessInfo.processInfo.environment
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: environment["BITAMP_CHIP_FILE"]!))
        let seconds = Double(environment["BITAMP_CHIP_SECONDS"] ?? "60")!
        let startSeconds = Double(environment["BITAMP_CHIP_START"] ?? "0")!
        let format = file.processingFormat
        let first = min(file.length, AVAudioFramePosition(startSeconds * format.sampleRate))
        file.framePosition = first
        let length = AVAudioFrameCount(min(Double(file.length - first), seconds * format.sampleRate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length))
        try file.read(into: buffer, frameCount: length)

        // Both channels as they are; a mono file plays as both.
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![min(1, channels - 1)]

        let transcriber = ChipTranscriber()
        transcriber.prepare(sampleRate: format.sampleRate)
        let synth = ChipSynth()
        synth.prepare(sampleRate: format.sampleRate)
        var chip = [Float](repeating: 0, count: count)
        var frames: [ChipTranscriber.Frame] = []
        var working = Duration.zero
        let clock = ContinuousClock()
        chip.withUnsafeMutableBufferPointer { output in
            var start = 0
            while start + ChipTranscriber.hop <= count {
                working += clock.measure {
                    transcriber.push(left: left + start, right: right + start, count: ChipTranscriber.hop)
                    synth.render(into: output.baseAddress! + start, count: ChipTranscriber.hop)
                    transcriber.analyze()
                    synth.play(transcriber.frame)
                }
                frames.append(transcriber.frame)
                start += ChipTranscriber.hop
            }
        }

        let duration = Double(count) / format.sampleRate
        let busy = Double(working.components.seconds) + Double(working.components.attoseconds) * 1e-18
        print(String(format: "CHIP cost: %.2f%% of real time on one core", busy / duration * 100))
        if environment["BITAMP_CHIP_TRACE"] != nil {
            // One line per hop: time, lead (* on an onset), chord, bass.
            func name(_ note: Int?) -> String { note.map(String.init) ?? "-" }
            for (i, frame) in frames.enumerated() {
                let time = Double(i * ChipTranscriber.hop) / format.sampleRate + startSeconds
                let chord = (0..<frame.chord.count).map { name(frame.chord[$0]) }.joined(separator: ",")
                print(String(format: "TRACE %6.2f %@%@ [%@] %@", time, name(frame.lead.note), frame.onset ? "*" : " ",
                             chord, name(frame.bass.note)))
            }
        }
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
        report("bass", \.bass)
        let onsets = frames.filter(\.onset).count
        print(String(format: "CHIP lead onsets: %.1f/s", Double(onsets) / duration))
        let chords = frames.map(\.chord)
        let chordChanges = zip(chords, chords.dropFirst()).filter { !$0.sameNotes(as: $1) }.count
        let chordActive = Double(chords.filter { $0.count > 0 }.count) / Double(chords.count)
        let notesPerChord = Double(chords.map(\.count).reduce(0, +)) / Double(max(1, chords.filter { $0.count > 0 }.count))
        print(String(format: "CHIP chord: %.1f changes/s, active %.0f%%, %.1f notes", Double(chordChanges) / duration,
                     chordActive * 100, notesPerChord))
        let drums: [ChipTranscriber.Drum] = frames.compactMap { $0.drum?.kind }
        let kicks = drums.filter { $0 == .kick }.count
        let snares = drums.filter { $0 == .snare }.count
        let hats = drums.filter { $0 == .hat }.count
        let rate = Double(drums.count) / duration
        print(String(format: "CHIP drums: %.1f/s (kick %d, snare %d, hat %d)", rate, kicks, snares, hats))
        if let out = environment["BITAMP_CHIP_OUT"] {
            let wavFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            let url = URL(fileURLWithPath: out).appendingPathComponent(environment["BITAMP_CHIP_NAME"] ?? "chip.wav")
            let wav = try AVAudioFile(forWriting: url, settings: wavFormat.settings)
            let outBuffer = try #require(AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: AVAudioFrameCount(count)))
            outBuffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { outBuffer.floatChannelData![0][i] = chip[i] * 0.8 }
            try wav.write(from: outBuffer)
            print("CHIP wrote \(url.path)")
        }
    }
}
