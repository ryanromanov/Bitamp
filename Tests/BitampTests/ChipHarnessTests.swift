import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// Runs a real song through the chiptune mode offline, for tuning it: prints how busy each
/// voice is and writes the chip version to WAV files. Off by default; run with
/// `BITAMP_CHIP_FILE=/path/to/song.mp3 BITAMP_CHIP_OUT=/some/folder scripts/test.sh --filter ChipHarness`.
/// `BITAMP_CHIP_START` and `BITAMP_CHIP_SECONDS` pick the clip (default: the first minute),
/// `BITAMP_CHIP_BLEND` (0...1) mixes in that much of the song, and `BITAMP_CHIP_NAME` names the files: NAME.wav from Basic Pitch's notes, as the app
/// plays it, and NAME-live.wav from the live `ChipTranscriber` alone.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_CHIP_FILE"] != nil))
struct ChipHarnessTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(fileURLWithPath: environment["BITAMP_CHIP_FILE"]!) }
    var start: Double { Double(environment["BITAMP_CHIP_START"] ?? "0")! }
    var seconds: Double { Double(environment["BITAMP_CHIP_SECONDS"] ?? "60")! }
    var name: String { environment["BITAMP_CHIP_NAME"] ?? "chip" }

    /// The clip, in the file's processing format.
    func clip() throws -> (file: AVAudioFile, buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = min(file.length, AVAudioFramePosition(start * format.sampleRate))
        let length = AVAudioFrameCount(min(Double(file.length - startFrame), seconds * format.sampleRate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, length)))
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: length)
        return (file, buffer, startFrame)
    }

    func write(_ samples: [Float], sampleRate: Double, suffix: String = "") throws {
        guard let out = environment["BITAMP_CHIP_OUT"] else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = URL(fileURLWithPath: out).appendingPathComponent("\(name)\(suffix).wav")
        let wav = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample * 0.8 }
        try wav.write(from: buffer)
        print("CHIP wrote \(url.path)")
    }

    /// Transcribes the clip with Basic Pitch, then plays it through the retro unit's kernel
    /// as the app would, with the render clock running from the clip's start.
    @Test func basicPitchCover() throws {
        let (file, buffer, startFrame) = try clip()
        let format = file.processingFormat
        let score = ChipScore(duration: Double(file.length) / format.sampleRate)
        // MSNet adds the vocal line unless BITAMP_CHIP_VOCAL=0.
        let vocal = environment["BITAMP_CHIP_VOCAL"] != "0"
        let transcription = try NoteTranscription(url: url, score: score, vocalModel: { vocal ? MSNet.shared : nil })
        // Arrangement styles to compare by ear: c (the default) as the app plays, a the full
        // arrangement, b the full one but quiet behind the voice, d vocal and bass only, and
        // e c with a steadier vocal line.
        switch environment["BITAMP_CHIP_STYLE"] {
        case "a": transcription.style = .full
        case "b":
            transcription.style = .full
            transcription.style.accompanyVocal = false
        case "d": transcription.style.shortestLead = .infinity
        case "e":
            transcription.style.vocalHoldRange = 1.0
            transcription.style.shortestVocalTicks = 8
        default: break
        }
        if let onset = environment["BITAMP_CHIP_ONSET"].flatMap(Float.init) { transcription.onsetThreshold = onset }
        if let frame = environment["BITAMP_CHIP_FRAME"].flatMap(Float.init) { transcription.frameThreshold = frame }
        let began = Date()
        try transcription.transcribe(from: start, to: start + seconds)
        let wall = Date().timeIntervalSince(began)
        print(String(format: "CHIP transcribed %.1f s in %.2f s (%.0f× real time; %.0f× counting only segment work)",
                     transcription.secondsTranscribed, wall, transcription.secondsTranscribed / wall,
                     transcription.secondsTranscribed / transcription.secondsSpent))

        let notes = transcription.notes.filter { $0.end > start && $0.start < start + seconds }
        let short = notes.filter { $0.end - $0.start < 0.1 }.count
        print(String(format: "CHIP notes: %d (%.1f/s, %d under 100 ms), pitches %d…%d", notes.count,
                     Double(notes.count) / seconds, short, notes.map(\.pitch).min() ?? 0, notes.map(\.pitch).max() ?? 0))
        if environment["BITAMP_CHIP_NOTES"] != nil {
            for note in notes.sorted(by: { ($0.start, $0.pitch) < ($1.start, $1.pitch) }) {
                print(String(format: "CHIP note %.3f %.3f %d %.2f", note.start - start, note.end - start, note.pitch, note.amplitude))
            }
        }

        let kernel = RetroAudioUnit.Kernel()
        let block = 512
        kernel.prepare(sampleRate: format.sampleRate, maxFrames: block)
        kernel.score = score
        kernel.mode = .chiptune
        kernel.blend = environment["BITAMP_CHIP_BLEND"].flatMap(Float.init) ?? 0
        kernel.setClock(offset: startFrame)
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
        var chip = [Float](repeating: 0, count: count)
        var position = 0
        while position < count {
            let n = min(block, count - position)
            chunk.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels {
                chunk.floatChannelData![c].update(from: buffer.floatChannelData![c] + position, count: n)
            }
            kernel.process(UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList), frames: n, sampleTime: Double(position))
            for i in 0..<n { chip[position + i] = chunk.floatChannelData![0][i] }
            position += n
        }

        // How busy each voice is, from the score.
        let ticks = (ChipScore.tick(at: start)..<ChipScore.tick(at: start + seconds)).compactMap { score.moment(at: $0) }
        func report(_ voice: String, _ note: (ChipMoment) -> UInt8, onset: UInt8) {
            let changes = zip(ticks, ticks.dropFirst()).filter { note($0) != note($1) }.count
            let attacks = ticks.filter { $0.onsets & onset != 0 }.count
            let active = Double(ticks.filter { note($0) != 0 }.count) / Double(max(1, ticks.count))
            print(String(format: "CHIP %@: %.1f changes/s, %.1f attacks/s, active %.0f%%",
                         voice, Double(changes) / seconds, Double(attacks) / seconds, active * 100))
        }
        report("lead", \.lead, onset: ChipMoment.leadOnset)
        report("chord", \.chord.0, onset: ChipMoment.chordOnset)
        report("bass", \.bass, onset: ChipMoment.bassOnset)

        // How much of a melody range the lead carries: of the moments where a note from
        // BITAMP_CHIP_MELODY (a MIDI range like 52-62; default C5 up) sounds, how many have
        // the lead playing one of those notes.
        let range = (environment["BITAMP_CHIP_MELODY"] ?? "72-127").split(separator: "-").compactMap { Int($0) }
        let melody = range[0]...range[1]
        var melodyMoments = 0, carried = 0
        for tick in ChipScore.tick(at: start)..<ChipScore.tick(at: start + seconds) {
            let time = Double(tick) * ChipScore.tickSeconds
            let sounding = notes.filter { melody.contains($0.pitch) && $0.start <= time && $0.end > time }
            guard !sounding.isEmpty, let moment = score.moment(at: tick) else { continue }
            melodyMoments += 1
            if sounding.contains(where: { $0.pitch == Int(moment.lead) }) { carried += 1 }
        }
        print(String(format: "CHIP melody notes %d-%d carried by the lead: %.0f%% of %d moments", melody.lowerBound,
                     melody.upperBound, Double(carried) / Double(max(1, melodyMoments)) * 100, melodyMoments))
        try write(chip, sampleRate: format.sampleRate)
    }

    /// The live transcriber alone, as before Basic Pitch, for comparison.
    @Test func liveTranscriber() throws {
        let (file, buffer, _) = try clip()
        let format = file.processingFormat
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
            print(String(format: "CHIP live %@: %.1f changes/s, active %.0f%%, jumps >7: %d of %d, median run %.0f ms",
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
        print(String(format: "CHIP live drums: %.1f/s (kick %d, snare %d, hat %d)", rate, kicks, snares, hats))
        try write(chip, sampleRate: format.sampleRate, suffix: "-live")
    }
}
