import BitampPakProtocol
import Foundation
import Testing
@testable import BitampKit

/// `--check-pak` on playback Paks, made of small shell programs that behave, or don't.
@MainActor @Suite struct PlaybackCheckTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("BitampPlaybackCheck-\(UUID().uuidString)")

    private func makePak(_ manifest: String, program: String) throws -> URL {
        let folder = root.appendingPathComponent("Radio.bitpak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("pak.json"), atomically: true, encoding: .utf8)
        let file = folder.appendingPathComponent("run")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return folder
    }

    private func manifest(protocol version: Int = 3) -> String {
        #"{"id":"radio","name":"Radio","version":"1.0","executable":"run","protocol":\#(version),"capabilities":["playback"]}"#
    }

    /// A Pak whose "player" is a shell loop: it reports as it should, unless told to be quiet
    /// about some state or to leave out the audio source.
    private func program(quietAbout quiet: String = "", audio: String = #","audio":"self""#, ticks: Bool = true) -> String {
        """
        #!/bin/sh
        ticker=""
        quiet="\(quiet)"
        stop_ticker() { if [ -n "$ticker" ]; then kill $ticker 2>/dev/null; ticker=""; fi; }
        state() { case "$quiet" in "$1") ;; *) printf '{"event":"state","track":"t1","state":"%s","position":%s}\\n' "$1" "$2" ;; esac; }
        start_ticker() { if [ "\(ticks)" = "true" ]; then (while true; do sleep 0.3; state playing 1; done) & ticker=$!; fi; }
        while read line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"hello"'*) printf '{"id":%s,"result":{"account":{"state":"connected"}}}\\n' "$id" ;;
            *'"method":"search"'*) printf '{"id":%s,"result":{"tracks":[{"id":"t1","title":"One","duration":20}]}}\\n' "$id" ;;
            *'"method":"track"'*) printf '{"id":%s,"result":{"track":{"id":"t1","title":"One","duration":20}}}\\n' "$id" ;;
            *'"method":"load"'*) printf '{"id":%s,"result":{"duration":20,"title":"One"\(audio)}}\\n' "$id" ;;
            *'"method":"play"'*) printf '{"id":%s,"result":{}}\\n' "$id"; state playing 0; start_ticker ;;
            *'"method":"seek"'*) printf '{"id":%s,"result":{}}\\n' "$id" ;;
            *'"method":"pause"'*) stop_ticker; printf '{"id":%s,"result":{}}\\n' "$id"; state paused 2 ;;
            *'"method":"resume"'*) printf '{"id":%s,"result":{}}\\n' "$id"; state playing 2; start_ticker ;;
            *'"method":"stop"'*) stop_ticker; printf '{"id":%s,"result":{}}\\n' "$id"; state stopped 0 ;;
            *'"method":"shutdown"'*) stop_ticker; printf '{"id":%s,"result":{}}\\n' "$id"; exit 0 ;;
          esac
        done

        """
    }

    private func check(_ manifest: String, _ program: String) async throws -> (passed: Bool, lines: [String]) {
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        let check = PakCheck(folder: try makePak(manifest, program: program)) { lines.append($0) }
        check.patience = 1
        return (await check.run(), lines)
    }

    @Test func aPakThatPlaysAsItShouldPasses() async throws {
        let (passed, lines) = try await check(manifest(), program())
        #expect(passed, "\(lines.joined(separator: "\n"))")
        #expect(lines.contains("✓ load “t1”: One, 20 s"))
        #expect(lines.contains("✓ load: the visualizer listens to “self”"))
        #expect(lines.contains("✓ play: the player reported playing"))
        #expect(lines.contains("✓ pause: the player reported paused"))
        #expect(lines.contains("✓ resume: the player reported playing"))
        #expect(lines.contains("✓ stop: the player reported stopped"))
        #expect(lines.contains { $0.contains("will play a few seconds") }, "it should say it makes sound")
        #expect(lines.last == "The Radio Pak looks good. Double-click it to install it.")
        // The events are routed to the check, not counted as stray output.
        #expect(!lines.contains { $0.contains("isn't an answer") })
    }

    @Test func aPakThatNeverSaysItIsPausedFails() async throws {
        let (passed, lines) = try await check(manifest(), program(quietAbout: "paused"))
        #expect(!passed)
        #expect(lines.contains { $0.hasPrefix("✗ pause: no \"state\" event said it was paused") }, "\(lines)")
    }

    @Test func aPakThatNeverReportsPlayingFails() async throws {
        let (passed, lines) = try await check(manifest(), program(quietAbout: "playing"))
        #expect(!passed)
        #expect(lines.contains { $0.hasPrefix("✗ play: no \"state\" event said it was playing") }, "\(lines)")
    }

    @Test func missingAudioIsAWarningAndAnUnknownOneIsAFailure() async throws {
        let (_, none) = try await check(manifest(), program(audio: ""))
        #expect(none.contains { $0.hasPrefix("! load: no \"audio\"") })
        let (passed, unknown) = try await check(manifest(), program(audio: #","audio":"com.apple.Safari""#))
        #expect(!passed)
        #expect(unknown.contains { $0.hasPrefix("✗ load: “com.apple.Safari” isn't an audio source Bitamp knows") })
    }

    @Test func reportingOnlyOnChangeIsAWarning() async throws {
        let (passed, lines) = try await check(manifest(), program(ticks: false))
        #expect(passed)
        #expect(lines.contains { $0.hasPrefix("! events: one report") })
    }

    @Test func aPlaybackManifestMustDeclareProtocolThree() async throws {
        let (passed, lines) = try await check(manifest(protocol: 2), program())
        #expect(!passed)
        #expect(lines.contains { $0.contains("“playback” capability needs \"protocol\": 3") })
    }
}

private final class DemoMarker {}

/// The demo playback Pak's real program, run by the host as Bitamp runs it. It makes sound, and
/// needs an audio device, so it only runs when BITAMP_PLAY_SOUND is set.
@MainActor @Suite struct DemoPlaybackPakTests {
    private static let enabled = ProcessInfo.processInfo.environment["BITAMP_PLAY_SOUND"] != nil

    @Test(.enabled(if: DemoPlaybackPakTests.enabled)) func passesTheCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BitampDemoPlayback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let program = Bundle(for: DemoMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BitampDemoPlaybackPak")
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/BitampDemoPlaybackPak/pak.json").standardizedFileURL
        let folder = root.appendingPathComponent("Demo Playback.bitpak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifest, to: folder.appendingPathComponent("pak.json"))
        try FileManager.default.copyItem(at: program, to: folder.appendingPathComponent("demo-playback-pak"))
        var lines: [String] = []
        let check = PakCheck(folder: folder, reservedIDs: ["applemusic"]) { lines.append($0) }
        #expect(await check.run(), "\(lines.joined(separator: "\n"))")
        #expect(lines.last == "The Demo Playback Pak looks good. Double-click it to install it.")
    }
}
