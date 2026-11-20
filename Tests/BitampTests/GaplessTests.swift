import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// Playing on from one file into the next without stopping, rendered offline so no audio
/// hardware is needed.
@MainActor @Suite struct GaplessTests {
    private var made: [URL] = []

    private func tone(_ seconds: Double, rate: Double = 44_100, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gapless-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.06) * 0.2 }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func offline() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, maximumFrameCount: 1_024)
        return engine
    }

    /// Renders `seconds` of audio, giving the main actor time to hear what finished.
    private func render(_ engine: AVAudioEngine, _ seconds: Double) async throws {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        var frames = 0
        while Double(frames) < seconds * 44_100, engine.isRunning {
            _ = try engine.renderOffline(1_024, to: out)
            frames += 1_024
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func playsOnIntoTheNextTrackWithoutStopping() async throws {
        let (a, b) = (try tone(0.5), try tone(0.5))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let avEngine = try offline()
        let engine = PlayerEngine(engine: avEngine)
        var advanced: [URL] = [], ended = 0
        engine.onTrackAdvance = { advanced.append($0) }
        engine.onTrackEnd = { ended += 1 }
        try engine.load(a)
        engine.play()
        #expect(engine.scheduleNext(b))
        #expect(engine.scheduledNext == b)

        // 0.7 s of sound: a (0.5 s) has ended and b has played 0.2 s. The player tells the engine
        // a has been heard to the end, as the hardware would.
        try await render(avEngine, 0.7)
        engine.segmentFinished(engine.generation)
        #expect(advanced == [b])
        #expect(ended == 0)
        #expect(engine.state == .playing)
        #expect(engine.track?.url == b)
        #expect(engine.scheduledNext == nil)
        // The position in b follows the player's clock across the join.
        #expect(abs(engine.currentTime - 0.2) < 0.15, "\(engine.currentTime)")

        // b ends: nothing follows it, so playback stops.
        engine.segmentFinished(engine.generation)
        #expect(ended == 1)
        #expect(engine.state == .stopped)
    }

    @Test func aDifferentFormatIsLeftForTheUsualChange() throws {
        let (a, mono, slow) = (try tone(0.5), try tone(0.5, channels: 1), try tone(0.5, rate: 22_050))
        defer { [a, mono, slow].forEach { try? FileManager.default.removeItem(at: $0) } }
        let engine = PlayerEngine(engine: try offline())
        try engine.load(a)
        // Not playing yet: nothing to follow.
        #expect(!engine.scheduleNext(a))
        engine.play()
        #expect(!engine.scheduleNext(mono))
        #expect(!engine.scheduleNext(slow))
        #expect(!engine.scheduleNext(URL(string: "fake://song/1")!))
        #expect(!engine.scheduleNext(URL(fileURLWithPath: "/nowhere/gone.wav")))
        #expect(engine.scheduledNext == nil)
    }

    @Test func notWithTheChiptuneCover() throws {
        let (a, b) = (try tone(0.5), try tone(0.5))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let engine = PlayerEngine(engine: try offline())
        try engine.load(a)
        engine.play()
        engine.retroSound = .chiptune
        #expect(!engine.scheduleNext(b))
    }

    @Test func aTakenBackTrackDoesNotPlay() async throws {
        let (a, b) = (try tone(0.5), try tone(0.5))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let avEngine = try offline()
        let engine = PlayerEngine(engine: avEngine)
        var advanced = 0, ended = 0
        engine.onTrackAdvance = { _ in advanced += 1 }
        engine.onTrackEnd = { ended += 1 }
        try engine.load(a)
        engine.play()
        #expect(engine.scheduleNext(b))
        engine.cancelNext()
        #expect(engine.scheduledNext == nil)
        #expect(engine.state == .playing)
        try await render(avEngine, 0.7)
        engine.segmentFinished(engine.generation)
        #expect(advanced == 0)
        #expect(ended == 1)
    }

    @Test func seekingAndPausingDropTheLinedUpTrack() throws {
        let (a, b) = (try tone(1), try tone(1))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let engine = PlayerEngine(engine: try offline())
        try engine.load(a)
        engine.play()
        #expect(engine.scheduleNext(b))
        engine.seek(to: 0.2)
        #expect(engine.scheduledNext == nil)
        #expect(engine.scheduleNext(b))
        engine.pause()
        #expect(engine.scheduledNext == nil)
    }

    // MARK: - The queue follows

    private func controller(_ avEngine: AVAudioEngine) -> PlaybackController {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampGapless-\(UUID().uuidString)")!)
        let player = PlayerEngine(engine: avEngine)
        let controller = PlaybackController(engine: player, preferences: preferences)
        controller.onError = { _ in }
        return controller
    }

    @Test func theQueueMovesOnWhenTheNextTrackTakesOver() async throws {
        let (a, b, c) = (try tone(0.5), try tone(0.5), try tone(0.5))
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        let avEngine = try offline()
        let controller = controller(avEngine)
        controller.open([a, b, c])
        #expect(controller.queue.current == a)
        // Within the last seconds of a short track, so the next is lined up at once.
        controller.tick()
        #expect(controller.engine.scheduledNext == b)
        try await render(avEngine, 0.7)
        controller.engine.segmentFinished(controller.engine.generation)
        #expect(controller.queue.current == b)
        #expect(controller.player.state == .playing)
        #expect(controller.player.nowPlaying?.url == b)
        // And on to c in the same way.
        controller.tick()
        #expect(controller.engine.scheduledNext == c)
    }

    @Test func changingTheQueueTakesBackTheLinedUpTrack() throws {
        let (a, b, c) = (try tone(1), try tone(1), try tone(1))
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        let controller = controller(try offline())
        controller.open([a, b, c])
        controller.tick()
        #expect(controller.engine.scheduledNext == b)
        // b is moved away from the front of what's next: c is next now.
        controller.move(IndexSet(integer: 1), by: 1)
        #expect(controller.engine.scheduledNext == nil)
        controller.tick()
        #expect(controller.engine.scheduledNext == c)
    }

    @Test func aTrackThatCantBeLinedUpIsNotTriedEveryFrame() throws {
        let (a, mono) = (try tone(0.5), try tone(0.5, channels: 1))
        defer { [a, mono].forEach { try? FileManager.default.removeItem(at: $0) } }
        let controller = controller(try offline())
        controller.open([a, mono])
        controller.tick()
        #expect(controller.engine.scheduledNext == nil)
        // Taken out of the way and put back: still not lined up, and no error.
        controller.tick()
        #expect(controller.engine.scheduledNext == nil)
    }

    @Test func canBeTurnedOff() throws {
        let (a, b) = (try tone(0.5), try tone(0.5))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let controller = controller(try offline())
        controller.gapless = false
        controller.open([a, b])
        controller.tick()
        #expect(controller.engine.scheduledNext == nil)
    }
}
