import Foundation
import Testing
@testable import BitampKit

/// The saved queue and reading folders, with fake files and nothing of the listener's own.
@MainActor @Suite struct SessionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("BitampSession-\(UUID().uuidString)")

    private func controller() -> PlaybackController {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampSession-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        controller.sessionFile = root.appendingPathComponent("Queue.m3u8")
        controller.onError = { _ in }
        return controller
    }

    private func files(_ names: [String]) throws -> [URL] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try names.map { name in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            return url
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theSavedTrackIsFoundByAddressNotJustPosition() {
        let urls = ["a", "b", "c", "d"].map { URL(string: "file:///music/\($0).mp3")! }
        // "c" was third; "a" has gone, so it's second now.
        let remaining = Array(urls.dropFirst())
        #expect(PlaybackController.restoredIndex(in: remaining, saved: (index: 2, track: urls[2].absoluteString)) == 1)
        // Gone itself: its old place, kept in range.
        #expect(PlaybackController.restoredIndex(in: remaining, saved: (index: 9, track: "file:///music/zzz.mp3")) == 2)
        #expect(PlaybackController.restoredIndex(in: remaining, saved: (index: nil, track: nil)) == nil)
        // The same file twice: the one nearest where it was.
        let twice = [urls[0], urls[1], urls[0]]
        #expect(PlaybackController.restoredIndex(in: twice, saved: (index: 2, track: urls[0].absoluteString)) == 2)
    }

    @Test func aFolderIsReadInTheBackgroundAndKeepsFinderOrder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try files(["album/10 ten.mp3", "album/2 two.mp3", "album/notes.txt", "album/disc2/1 one.mp3"])
        let controller = controller()
        var readings: [Bool] = []
        controller.onReading = { readings.append($0) }
        controller.open([root.appendingPathComponent("album")])
        #expect(controller.isReading)
        #expect(controller.queue.isEmpty)
        try await wait { controller.queue.count == 3 && !controller.isReading }
        #expect(controller.queue.items.map(\.lastPathComponent) == ["2 two.mp3", "10 ten.mp3", "1 one.mp3"])
        #expect(readings == [true, false])
    }

    @Test func plainFilesAreReadAtOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(["one.mp3", "two.mp3"])
        let controller = controller()
        controller.enqueue(urls)
        #expect(controller.queue.items == urls)
        #expect(!controller.isReading)
    }

    @Test func readsHappenInTheOrderAsked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try files(["a/1.mp3", "b/2.mp3"])
        let single = try files(["solo.mp3"])
        let controller = controller()
        controller.enqueue([root.appendingPathComponent("a")])
        controller.enqueue([root.appendingPathComponent("b")])
        // A plain file asked for while folders are still being read waits its turn.
        controller.enqueue(single)
        try await wait { controller.queue.count == 3 }
        #expect(controller.queue.items.map(\.lastPathComponent) == ["1.mp3", "2.mp3", "solo.mp3"])
    }

    @Test func theQueueSavesItselfAfterChangesAndComesBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(["a.mp3", "b.mp3", "c.mp3"])
        let first = controller()
        first.autosavesSession = true
        first.autosaveDelay = 0.05
        first.enqueue(urls)
        first.playItem(at: 2)
        try await wait { FileManager.default.fileExists(atPath: first.sessionFile.path) }
        try await Task.sleep(for: .milliseconds(200))

        let second = controller()
        second.sessionFile = first.sessionFile
        // The same preferences: where it was is kept there.
        let defaults = UserDefaults(suiteName: "BitampSession-restore-\(UUID().uuidString)")!
        defaults.set(2, forKey: "queueIndex")
        defaults.set(urls[2].absoluteString, forKey: "queueTrack")
        let restoring = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: defaults))
        restoring.sessionFile = first.sessionFile
        restoring.onError = { _ in }
        restoring.restoreSession()
        try await wait { restoring.queue.count == 3 }
        #expect(restoring.queue.items.map(\.lastPathComponent) == ["a.mp3", "b.mp3", "c.mp3"])
        #expect(restoring.queue.currentIndex == 2)
        _ = second
    }

    @Test func nothingIsSavedUnlessTheAppAsks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(["a.mp3"])
        let controller = controller()
        controller.autosaveDelay = 0.01
        controller.enqueue(urls)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: controller.sessionFile.path))
    }

    @Test func aFileThatCantLoadDoesNotMoveTheSavedPosition() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Empty files don't load, but restoring stays where the listener was, not skipping on.
        let urls = try files(["a.mp3", "b.mp3", "c.mp3"])
        let writer = controller()
        writer.setQueueItems(urls, current: 1)
        try writer.savePlaylist(to: writer.sessionFile)
        let defaults = UserDefaults(suiteName: "BitampSession-skip-\(UUID().uuidString)")!
        defaults.set(1, forKey: "queueIndex")
        defaults.set(urls[1].absoluteString, forKey: "queueTrack")
        let restoring = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: defaults))
        restoring.sessionFile = writer.sessionFile
        restoring.onError = { _ in }
        restoring.restoreSession()
        try await wait { restoring.queue.count == 3 }
        #expect(restoring.queue.currentIndex == 1, "index \(String(describing: restoring.queue.currentIndex)) of \(restoring.queue.items.map(\.lastPathComponent))")
    }
}
