import BitampPakKit
import BitampPakProtocol
import Foundation
import Testing
@testable import BitampKit

/// A Pak's player, faked: it records the commands it's given in order, can be made slow, and
/// says what its player does on request.
@MainActor
private final class FakeTransport: PakPlaybackTransport {
    var calls: [String] = []
    var onPlaybackEvent: ((PakPlaybackEvent) -> Void)?
    var onProgramExit: (() -> Void)?
    var audioProcessID: Int32? = 4242
    var loadResult = PakMethod.LoadResult(duration: 30, title: "Ode", artist: "Beethoven", audio: PakAudioProcess.itself)
    /// Loads that wait to be released (or cancelled), by track id.
    var slowLoads: Set<String> = []
    var release: [String: CheckedContinuation<Void, Never>] = [:]
    var failNext: String?

    func load(trackID: String) async throws -> PakMethod.LoadResult {
        calls.append("load \(trackID)")
        if slowLoads.contains(trackID) {
            // Waits until released, or until the task is cancelled.
            while slowLoads.contains(trackID) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return loadResult
    }

    func command(_ method: String) async throws {
        calls.append(method)
        if let failNext, failNext == method {
            self.failNext = nil
            throw PakConnection.Failure.pak("No \(method) for you")
        }
    }

    func seek(to seconds: Double) async throws { calls.append("seek \(seconds)") }

    func send(_ event: PakPlaybackEvent) { onPlaybackEvent?(event) }
}

@MainActor @Suite struct ExternalBackendTests {
    private let url = URL(string: "bitpak-radio://track/ode")!
    private let other = URL(string: "bitpak-radio://track/fur-elise")!

    private func make(_ given: FakeTransport? = nil) -> (ExternalBackend, FakeTransport) {
        let transport = given ?? FakeTransport()
        let backend = ExternalBackend(transport: transport, name: "Radio") { url in
            url.scheme == "bitpak-radio" && url.host == "track" ? String(url.path.dropFirst()) : nil
        }
        return (backend, transport)
    }

    /// Waits for the Pak to have been given `count` commands.
    private func waitForCalls(_ transport: FakeTransport, _ count: Int) async throws {
        for _ in 0..<500 where transport.calls.count < count { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(transport.calls.count >= count, "only \(transport.calls)")
    }

    private func event(_ kind: String = "state", track: String? = "ode", state: PakPlayerState? = nil,
                       position: Double? = nil, duration: Double? = nil, message: String? = nil) -> PakPlaybackEvent {
        PakPlaybackEvent(event: kind, track: track, state: state, position: position, duration: duration, message: message)
    }

    @Test func loadsTheTrackAndShowsWhatThePakSaid() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        #expect(backend.nowPlaying?.title == "Radio", "a placeholder until the Pak answers")
        try await waitForCalls(transport, 1)
        for _ in 0..<100 where backend.nowPlaying?.title == "Radio" { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(backend.nowPlaying?.title == "Ode" && backend.nowPlaying?.artist == "Beethoven")
        #expect(backend.nowPlaying?.duration == 30)
        #expect(backend.state == .stopped)
        #expect(throws: ExternalBackend.Failure.self) { try backend.load(URL(string: "bitpak-other://track/x")!) }
    }

    @Test func sendsCommandsInTheOrderTheyWereGiven() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        backend.play()
        backend.pause()
        backend.pause()        // pause toggles: resumes
        backend.seek(to: 12)
        backend.stop()
        try await waitForCalls(transport, 6)
        #expect(transport.calls == ["load ode", "play", "pause", "resume", "seek 12.0", "stop"])
        #expect(backend.state == .stopped)
    }

    @Test func stateMovesAtOnceAndASlowReportDoesNotUndoIt() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        backend.play()
        #expect(backend.state == .playing)
        backend.pause()
        #expect(backend.state == .paused)
        // The Pak's last report was made before it heard the pause.
        transport.send(event(state: .playing, position: 3))
        #expect(backend.state == .paused, "an old report undid the pause")
        try await waitForCalls(transport, 3)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 4_000_000) }
        // With nothing pending, what the Pak says is believed: paused from outside Bitamp, say.
        transport.send(event(state: .paused, position: 5))
        #expect(backend.state == .paused)
        transport.send(event(state: .playing, position: 6))
        #expect(backend.state == .playing)
    }

    @Test func theClockFollowsTheReportsAndStopsAtTheEnd() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        backend.play()
        try await waitForCalls(transport, 2)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 4_000_000) }
        transport.send(event(state: .playing, position: 29.9, duration: 30))
        #expect(abs(backend.currentTime - 29.9) < 0.2)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(backend.currentTime == 30, "the clock ran past the end")
        transport.send(event(state: .paused, position: 12))
        #expect(backend.currentTime == 12)
    }

    @Test func endingAndErrorsReachTheController() async throws {
        let (backend, transport) = make()
        var ended = 0
        var failures: [String] = []
        backend.onTrackEnd = { ended += 1 }
        backend.onLoadFailure = { failures.append($0.localizedDescription) }
        try backend.load(url)
        backend.play()
        try await waitForCalls(transport, 2)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 4_000_000) }

        transport.send(event("ended"))
        #expect(ended == 1 && backend.state == .stopped)

        backend.play()
        transport.send(event("error", message: "The stream dropped."))
        #expect(failures == ["The stream dropped."] && backend.state == .stopped)
    }

    @Test func ignoresWordAboutAnEarlierTrack() async throws {
        let (backend, transport) = make()
        var ended = 0
        backend.onTrackEnd = { ended += 1 }
        try backend.load(other)
        try await waitForCalls(transport, 1)
        transport.send(event("ended", track: "ode"))
        transport.send(event(track: "ode", state: .playing, position: 9))
        #expect(ended == 0 && backend.state == .stopped && backend.currentTime == 0)
    }

    @Test func aNewLoadCancelsASlowOneAndDropsWhatWasWaitingOnIt() async throws {
        let transport = FakeTransport()
        transport.slowLoads = ["ode"]
        let (backend, _) = make(transport)
        try backend.load(url)
        backend.play()                 // belongs to the first load
        try await waitForCalls(transport, 1)
        try backend.load(other)        // the user skipped
        backend.play()
        try await waitForCalls(transport, 3)
        #expect(transport.calls == ["load ode", "load fur-elise", "play"], "\(transport.calls)")
    }

    @Test func aFailedCommandIsReportedOnce() async throws {
        let (backend, transport) = make()
        transport.failNext = "play"
        var failures = 0
        backend.onLoadFailure = { _ in failures += 1 }
        try backend.load(url)
        backend.play()
        try await waitForCalls(transport, 2)
        for _ in 0..<100 where failures == 0 { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(failures == 1 && backend.state == .stopped)
    }

    @Test func aProgramThatExitsMidSongStopsAndLoadsAgainOnTheNextPlay() async throws {
        let (backend, transport) = make()
        var failures: [String] = []
        backend.onLoadFailure = { failures.append($0.localizedDescription) }
        try backend.load(url)
        backend.play()
        try await waitForCalls(transport, 2)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 4_000_000) }

        transport.onProgramExit?()
        #expect(backend.state == .stopped)
        #expect(failures == ["The Radio Pak stopped running."])

        // The new program knows nothing of the track, so it's loaded again before it plays.
        backend.play()
        try await waitForCalls(transport, 4)
        #expect(transport.calls == ["load ode", "play", "load ode", "play"], "\(transport.calls)")
    }

    @Test func theVisualizerListensOnlyToWhatThePakIsAllowedToName() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        try await waitForCalls(transport, 1)
        for _ in 0..<100 where backend.audioSource == nil { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(backend.audioSource == .processID(4242))

        transport.loadResult.audio = PakAudioProcess.appleMusic
        try backend.load(other)
        for _ in 0..<100 where backend.audioSource != .appleMusicPlayer { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(backend.audioSource == .appleMusicPlayer)

        // A Pak can't point Bitamp's permission to record at any app it likes.
        transport.loadResult.audio = "com.apple.Safari"
        try backend.load(url)
        try await waitForCalls(transport, 3)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(backend.audioSource == nil)
    }

    @Test func playingAfterAPauseResumesRatherThanRestarting() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        backend.play()
        backend.pause()
        backend.play()
        try await waitForCalls(transport, 4)
        #expect(transport.calls == ["load ode", "play", "pause", "resume"])
    }

    @Test func seekingIsIgnoredWhenNothingPlays() async throws {
        let (backend, transport) = make()
        try backend.load(url)
        backend.seek(to: 10)
        try await waitForCalls(transport, 1)
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 4_000_000) }
        #expect(transport.calls == ["load ode"])
    }
}

/// The connection's own handling of a playback Pak: events are routed, not logged as stray output.
@MainActor @Suite struct PlaybackConnectionTests {
    private func program(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BitampPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("run")
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func eventsAreRoutedAndNotTreatedAsStrayOutput() async throws {
        let file = try program("""
            #!/bin/sh
            while read line; do
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
              case "$line" in
                *'"method":"hello"'*) printf '{"id":%s,"result":{"account":{"state":"connected"}}}\\n' "$id" ;;
                *'"method":"play"'*)
                  printf '{"event":"state","track":"t","state":"playing","position":1.5}\\n'
                  printf '{"id":%s,"result":{}}\\n' "$id"
                  printf '{"event":"ended","track":"t"}\\n' ;;
                *'"method":"shutdown"'*) printf '{"id":%s,"result":{}}\\n' "$id"; exit 0 ;;
              esac
            done

            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let connection = PakConnection(executable: file, name: "Radio") {
            (PakMethod.hello, PakMethod.Hello(protocol: PakProtocol.version, settings: [:], cacheDirectory: "/tmp"))
        }
        var events: [PakPlaybackEvent] = []
        var stray: [String] = []
        var exits = 0
        connection.onEvent = { events.append($0) }
        connection.onUnexpectedOutput = { stray.append($0) }
        connection.onExit = { exits += 1 }

        _ = try await connection.request(PakMethod.play, PakMethod.Empty(), as: PakMethod.Empty.self)
        for _ in 0..<200 where events.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(events.map(\.event) == ["state", "ended"])
        #expect(events.first?.state == .playing && events.first?.position == 1.5 && events.first?.track == "t")
        #expect(stray.isEmpty, "\(stray)")
        #expect((connection.processIdentifier ?? 0) > 0)

        connection.shutdown()
        for _ in 0..<200 where exits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(exits == 1)
    }
}
