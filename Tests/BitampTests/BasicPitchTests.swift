import AVFoundation
import Foundation
import Testing
@testable import BitampKit

@Suite struct BasicPitchTests {
    static let sampleRate = 44_100.0
    /// C4, E4, G4, C5, half a second each, from a quarter second in.
    static let arpeggio = [60, 64, 67, 72]
    static let noteStart = 0.25, noteLength = 0.5

    /// Writes the arpeggio, as tones with a few harmonics, to a WAV file and returns its URL.
    static func arpeggioFile() throws -> URL {
        let count = Int((noteStart + Double(arpeggio.count) * noteLength + 0.5) * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        for (index, note) in arpeggio.enumerated() {
            let start = Int((noteStart + Double(index) * noteLength) * sampleRate)
            let length = Int(noteLength * sampleRate)
            let frequency = ChipTranscriber.frequency(of: note)
            for i in 0..<length {
                // A quick attack and a gentle decay, like a plucked string.
                let t = Double(i) / sampleRate
                let envelope = min(1, t / 0.005) * exp(-t * 2) * min(1, Double(length - i) / 200)
                var sample = 0.0
                for h in 1...4 { sample += sin(2 * .pi * frequency * Double(h) * t) / Double(h) }
                for channel in 0..<2 { buffer.floatChannelData![channel][start + i] = Float(0.25 * envelope * sample) }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitamp-arpeggio-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func modelLoads() throws {
        #expect(BasicPitch.modelURL() != nil)
        #expect(BasicPitch.shared != nil)
    }

    @Test func hearsAnArpeggio() throws {
        let url = try Self.arpeggioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = Self.noteStart + Double(Self.arpeggio.count) * Self.noteLength + 0.5
        let score = ChipScore(duration: duration)
        let transcription = try NoteTranscription(url: url, score: score)
        try transcription.transcribe(from: 0, to: duration)
        let notes = transcription.notes
        for (index, pitch) in Self.arpeggio.enumerated() {
            let start = Self.noteStart + Double(index) * Self.noteLength
            let found = notes.contains { $0.pitch == pitch && abs($0.start - start) < 0.05 && $0.end - $0.start > 0.25 }
            #expect(found, "no \(pitch) at \(start) s in \(notes)")
        }
        // Anything else is a faint, brief overtone, which the arrangement leaves out.
        let others = notes.filter { !Self.arpeggio.contains($0.pitch) || $0.end - $0.start < 0.25 }
        #expect(others.allSatisfy { $0.amplitude < 0.5 && $0.end - $0.start < 0.25 }, "\(notes)")

        // The score plays each note on the lead in its turn, starting it with an onset.
        for (index, pitch) in Self.arpeggio.enumerated() {
            let start = Self.noteStart + Double(index) * Self.noteLength
            let middle = try #require(score.moment(at: ChipScore.tick(at: start + Self.noteLength / 2)))
            #expect(Int(middle.lead) == pitch || Int(middle.bass) == pitch, "\(middle)")
            // The overtones heard as faint notes aren't arranged as a chord.
            let ticks = ChipScore.tick(at: start)..<ChipScore.tick(at: start + Self.noteLength - 0.05)
            #expect(ticks.allSatisfy { score.moment(at: $0)?.chord.0 == 0 })
            let onsets = (-3...3).compactMap { score.moment(at: ChipScore.tick(at: start) + $0) }
            #expect(onsets.contains { $0.onsets != 0 })
        }
        #expect(score.moment(at: ChipScore.tick(at: 0.1))?.lead == 0)
        #expect(transcription.secondsTranscribed >= duration - 0.1)
    }

    @Test func decodesOnsetsIntoNotes() {
        // One note from frame 10 to 40 at A4, with an onset at frame 10; nothing else.
        let n = 60, width = BasicPitch.noteCount, f = 69 - BasicPitch.lowestNote
        var frames = [Float](repeating: 0, count: n * width)
        var onsets = frames
        for t in 10..<40 { frames[t * width + f] = 0.8 }
        onsets[10 * width + f] = 0.9
        let notes = BasicPitch.decodeNotes(frames: frames, onsets: onsets, count: n, minimumLength: 3)
        #expect(notes.count == 1)
        #expect(notes.first?.pitch == 69)
        #expect(notes.first?.start == 10)
        #expect(notes.first?.end == 40)
        // Already known, it isn't found again.
        #expect(BasicPitch.decodeNotes(frames: frames, onsets: onsets, count: n, known: notes, minimumLength: 3).isEmpty)
    }

    @Test func scoreReadsOnlyWhatsReady() {
        let score = ChipScore(duration: 1)
        #expect(score.moment(at: 5) == nil)
        var moment = ChipMoment()
        moment.lead = 69
        moment.leadLevel = 12
        score.write(moment, at: 5)
        #expect(score.moment(at: 5) == moment)
        #expect(score.moment(at: -1) == nil)
        #expect(score.moment(at: score.count) == nil)
    }

    @Test func arpeggiatesTheChord() {
        let synth = ChipSynth()
        synth.prepare(sampleRate: Self.sampleRate)
        var moment = ChipMoment()
        moment.chord = (60, 64, 67)
        moment.chordLevel = 15
        moment.onsets = ChipMoment.chordOnset
        synth.play(moment)
        // Each step of the arpeggio is about 23 ms; count rising edges in three of them.
        let step = Int(ChipSynth.arpeggioStep * Self.sampleRate)
        var samples = [Float](repeating: 0, count: step * 3)
        samples.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, count: $0.count) }
        func rising(_ part: ArraySlice<Float>) -> Int { zip(part, part.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count }
        let counts = (0..<3).map { rising(samples[($0 * step)..<(($0 + 1) * step)]) }
        // C4, E4 and G4 cycle 262, 330 and 392 times a second.
        #expect(counts[0] < counts[1] && counts[1] < counts[2], "\(counts)")
    }

    /// The render clock that `PlayerEngine` works out from the player puts the chip's idea
    /// of the file frame where the music actually is: a click at a known frame of the file
    /// comes out of the retro unit at that frame.
    @MainActor @Test func clockFollowsThePlayer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let length = 44_100, click = 30_000, startFrame: AVAudioFramePosition = 10_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
        buffer.frameLength = AVAudioFrameCount(length)
        for channel in 0..<2 { buffer.floatChannelData![channel][click] = 1 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitamp-click-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let file = try AVAudioFile(forReading: url)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let retro = RetroAudioUnit.makeNode()
        engine.attach(player)
        engine.attach(retro)
        engine.connect(player, to: retro, format: file.processingFormat)
        engine.connect(retro, to: engine.mainMixerNode, format: file.processingFormat)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let kernel = (retro.auAudioUnit as! RetroAudioUnit).kernel
        try engine.start()
        // Render a little before playing, so the render clock isn't at zero when it starts.
        let out = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        _ = try engine.renderOffline(300, to: out)
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(length) - AVAudioFrameCount(startFrame), at: nil)
        player.play()

        var offset: Int64?
        var heard: Int64?
        for _ in 0..<100 where heard == nil {
            _ = try engine.renderOffline(512, to: out)
            if offset == nil { offset = PlayerEngine.clockOffset(player: player, startFrame: startFrame) }
            let data = out.floatChannelData![0]
            if let i = (0..<Int(out.frameLength)).first(where: { abs(data[$0]) > 0.5 }),
               let offset, let time = kernel.lastSampleTime {
                heard = Int64(time) + Int64(i) + offset
            }
        }
        engine.stop()
        #expect(offset != nil)
        #expect(heard == Int64(click))
    }
}
