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
        var score = ChipScore(duration: Double(file.length) / format.sampleRate)
        // MSNet adds the vocal line unless a pitch track stands in for it or BITAMP_CHIP_VOCAL=0.
        let vocal = environment["BITAMP_CHIP_LEAD"] == nil && environment["BITAMP_CHIP_VOCAL"] != "0"
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
        if let path = environment["BITAMP_CHIP_LEAD"] {
            score = try Self.withLead(fromPitchTrack: path, clipStart: start, seconds: seconds, over: score,
                                      adding: environment["BITAMP_CHIP_LEAD_MODE"] == "add")
        }
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

    /// The score with its lead replaced by a vocal melody, from a pitch track (lines of
    /// "seconds hertz", from the clip's start; 0 Hz is unvoiced) such as MSNet's. Each tick
    /// takes the median voiced pitch in it; notes hold within 0.8 semitone so vibrato
    /// doesn't split them, last at least 4 ticks, and short unvoiced gaps are bridged.
    /// When `adding`, the score's own lead isn't dropped: while the vocal sounds it moves to
    /// the chord voice in place of the arpeggio, quieter, and elsewhere it stays the lead.
    static func withLead(fromPitchTrack path: String, clipStart: Double, seconds: Double, over score: ChipScore,
                         adding: Bool = false) throws -> ChipScore {
        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { line -> (Double, Double)? in
            let parts = line.split(separator: " ").compactMap { Double($0) }
            return parts.count >= 2 ? (parts[0], parts[1]) : nil
        }
        let first = ChipScore.tick(at: clipStart), last = ChipScore.tick(at: clipStart + seconds)
        // A pitch per tick, in fractional MIDI notes.
        var pitches = [Double?](repeating: nil, count: last - first)
        var row = 0
        for i in pitches.indices {
            let from = Double(first + i) * ChipScore.tickSeconds - clipStart, to = from + ChipScore.tickSeconds
            var voiced: [Double] = [], total = 0
            while row < rows.count && rows[row].0 < to {
                if rows[row].0 >= from {
                    total += 1
                    if rows[row].1 > 0 { voiced.append(69 + 12 * log2(rows[row].1 / 440)) }
                }
                row += 1
            }
            if voiced.count * 2 >= max(1, total) { pitches[i] = voiced.sorted()[voiced.count / 2] }
        }
        // Into notes.
        var notes = [Int?](repeating: nil, count: pitches.count)
        var current: Int?
        var gap = 0
        for i in pitches.indices {
            guard let pitch = pitches[i] else {
                gap += 1
                notes[i] = gap <= 3 ? current : nil
                if gap > 3 { current = nil }
                continue
            }
            gap = 0
            if let note = current, abs(pitch - Double(note)) < 0.8 {
                notes[i] = note
            } else {
                current = Int(pitch.rounded())
                notes[i] = current
            }
        }
        // Notes shorter than 4 ticks join the note before them.
        var i = 0
        while i < notes.count {
            var j = i
            while j < notes.count && notes[j] == notes[i] { j += 1 }
            if notes[i] != nil && j - i < 4 && i > 0 {
                for k in i..<j { notes[k] = notes[i - 1] }
            }
            i = j
        }

        let result = ChipScore(duration: Double(score.count) * ChipScore.tickSeconds)
        for (index, note) in notes.enumerated() {
            var moment = score.moment(at: first + index) ?? ChipMoment()
            if adding && note == nil {
                result.write(moment, at: first + index)
                continue
            }
            let ownLead = moment.lead, ownLevel = moment.leadLevel, ownOnset = moment.onsets & ChipMoment.leadOnset != 0
            moment.onsets &= ~ChipMoment.leadOnset
            if adding, let note, ownLead != 0, ownLead != UInt8(note) {
                moment.chord = (ownLead, 0, 0)
                moment.chordLevel = UInt8(max(1, (Float(ownLevel) * 0.7).rounded()))
                if ownOnset { moment.onsets |= ChipMoment.chordOnset }
            }
            if let note {
                let level = max(moment.leadLevel, moment.bassLevel, moment.chordLevel, 8)
                moment.lead = UInt8(note)
                moment.leadLevel = level
                if index == 0 || notes[index - 1] != note { moment.onsets |= ChipMoment.leadOnset }
            } else {
                moment.lead = 0
                moment.leadLevel = 0
            }
            result.write(moment, at: first + index)
        }
        return result
    }
}
