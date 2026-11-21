import BitampPakProtocol
import BitampPakSDK
import Foundation
import Testing
@testable import BitampKit

/// A Pak that plays its own audio, with the player faked: it records what it was told and
/// reports back through the reporter, as a real one reports its player.
private final class FakePlayer: PakProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var reporter: PakPlaybackReporter?
    /// Held until released, to make a search slow.
    let searchGate = DispatchSemaphore(value: 0)
    /// Makes `load` wait until it's cancelled.
    var loadsForever = false

    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }

    func attach(_ reporter: PakPlaybackReporter) { self.reporter = reporter }

    func search(_ term: String) async throws -> [PakTrackInfo] {
        record("search")
        await Task.detached { self.searchGate.wait() }.value
        return []
    }

    func load(id: String) async throws -> PakPlaybackLoad {
        record("load \(id)")
        if loadsForever {
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        return PakPlaybackLoad(duration: 90, title: "Track \(id)", artist: "Nobody", audio: PakAudioProcess.itself)
    }

    func play() async throws {
        record("play")
        reporter?.report(.playing, position: 0, duration: 90)
    }

    func pause() async throws {
        record("pause")
        reporter?.report(.paused, position: 4.5)
    }

    func resume() async throws { record("resume") }
    func stop() async throws { record("stop") }

    func seek(to seconds: Double) async throws {
        record("seek \(seconds)")
        reporter?.ended()
    }
}

/// Lines from the Pak, safe to read while the request loop appends to them.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func contains(_ text: String) -> Bool { all.contains { $0.contains(text) } }
}

@Suite struct PlaybackPakTests {
    @Test func answersPlaybackCommandsInOrderAndReportsWhatThePlayerDoes() async {
        let player = FakePlayer()
        let requests = [
            #"{"id":1,"method":"load","params":{"id":"ode"}}"#,
            #"{"id":2,"method":"play","params":{}}"#,
            #"{"id":3,"method":"pause","params":{}}"#,
            #"{"id":4,"method":"resume","params":{}}"#,
            #"{"id":5,"method":"seek","params":{"seconds":12.5}}"#,
            #"{"id":6,"method":"stop","params":{}}"#,
        ]
        let lines = Lines()
        await PakRunner.serve(player, input: AsyncStream { continuation in
            requests.forEach { continuation.yield($0) }
            continuation.finish()
        }) { lines.add($0) }

        #expect(player.recorded == ["load ode", "play", "pause", "resume", "seek 12.5", "stop"])
        let all = lines.all
        // Answers carry their request's id; events don't, and name the track.
        #expect(all.contains(#"{"id":1,"result":{"artist":"Nobody","audio":"self","duration":90,"title":"Track ode"}}"#))
        for id in 2...6 { #expect(all.contains(#"{"id":\#(id),"result":{}}"#)) }
        #expect(all.contains(#"{"duration":90,"event":"state","position":0,"state":"playing","track":"ode"}"#))
        #expect(all.contains(#"{"event":"state","position":4.5,"state":"paused","track":"ode"}"#))
        #expect(all.contains(#"{"event":"ended","track":"ode"}"#))
    }

    @Test func aSlowSearchDoesNotHoldUpAPause() async throws {
        let player = FakePlayer()
        let lines = Lines()
        let (input, feed) = AsyncStream<String>.makeStream()
        let serving = Task { await PakRunner.serve(player, input: input) { lines.add($0) } }

        feed.yield(#"{"id":1,"method":"search","params":{"term":"slow"}}"#)
        feed.yield(#"{"id":2,"method":"pause","params":{}}"#)
        // The pause is answered while the search is still waiting.
        for _ in 0..<200 where !lines.contains(#""id":2"#) { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(lines.contains(#""id":2"#), "the pause waited behind the search")
        #expect(!lines.contains(#""id":1"#))

        player.searchGate.signal()
        for _ in 0..<200 where !lines.contains(#""id":1"#) { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(lines.contains(#""id":1"#))
        feed.finish()
        await serving.value
    }

    @Test func aCancelledLoadStopsAndIsNotAnswered() async throws {
        let player = FakePlayer()
        player.loadsForever = true
        let lines = Lines()
        let (input, feed) = AsyncStream<String>.makeStream()
        let serving = Task { await PakRunner.serve(player, input: input) { lines.add($0) } }

        feed.yield(#"{"id":1,"method":"load","params":{"id":"slow"}}"#)
        for _ in 0..<200 where player.recorded.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        feed.yield(#"{"id":2,"method":"cancel","params":{"id":1}}"#)
        feed.yield(#"{"id":3,"method":"stop","params":{}}"#)
        // The next command, on the same line, runs once the cancelled load has stopped.
        for _ in 0..<200 where !lines.contains(#""id":3"#) { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(lines.contains(#""id":3"#))
        #expect(!lines.contains(#""id":1"#), "a cancelled load was answered")
        feed.finish()
        await serving.value
    }

    @Test func aPakThatDoesNotPlayRefusesPlaybackCommands() async {
        let lines = Lines()
        await PakRunner.serve(NoPlayback(), input: AsyncStream { continuation in
            continuation.yield(#"{"id":1,"method":"load","params":{"id":"x"}}"#)
            continuation.yield(#"{"id":2,"method":"play","params":{}}"#)
            continuation.finish()
        }) { lines.add($0) }
        #expect(lines.all.contains(#"{"error":{"message":"This Pak doesn't play its own audio."},"id":1}"#))
        #expect(lines.all.contains(#"{"error":{"message":"This Pak doesn't play its own audio."},"id":2}"#))
    }

    @Test func eventsAndLoadResultsEncodeAsDocumented() throws {
        let event = PakPlaybackEvent(event: PakPlaybackEvent.state, track: "t", state: .playing, position: 1.5, duration: 30)
        let decoded = try JSONDecoder().decode(PakPlaybackEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        // A line from a newer Pak with fields we don't know still reads.
        let future = try JSONDecoder().decode(PakPlaybackEvent.self, from: Data(#"{"event":"state","state":"paused","bitrate":320}"#.utf8))
        #expect(future.state == .paused && future.track == nil)
        #expect(PakProtocol.version == 3 && PakProtocol.playbackVersion == 3)
        #expect(PakProtocol.knownCapabilities.contains(PakProtocol.playback))
        #expect(PakAudioProcess.known == ["self", "apple-music"])
    }
}

private final class NoPlayback: PakProvider {}
