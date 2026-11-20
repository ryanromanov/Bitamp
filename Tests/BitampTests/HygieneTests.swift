import Foundation
import Testing
@testable import BitampKit

@Suite struct LineBufferTests {
    private func text(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test func splitsLinesAndKeepsAPartialOne() {
        let buffer = LineBuffer()
        #expect(text(buffer.append(Data("one\ntwo\nthr".utf8))) == ["one", "two"])
        #expect(text(buffer.append(Data("ee\n".utf8))) == ["three"])
    }

    @Test func dropsALineThatNeverEndsAndCarriesOn() {
        let buffer = LineBuffer(maxLine: 10)
        // No line break in more than ten bytes: dropped, including what follows up to its end.
        #expect(buffer.append(Data(repeating: 0x61, count: 12)).isEmpty)
        #expect(buffer.append(Data(repeating: 0x61, count: 50)).isEmpty)
        #expect(text(buffer.append(Data("tail\nnext\n".utf8))) == ["next"])
        // And it's back to normal.
        #expect(text(buffer.append(Data("ok\n".utf8))) == ["ok"])
    }
}

@MainActor @Suite struct TrackInfoQueueTests {
    @Test func loadsInTheOrderRequestedWhateverTheLength() async throws {
        let store = TrackInfoStore()
        var asked: [URL] = []
        store.loadExternal = { url in
            asked.append(url)
            return TrackMetadata(title: url.lastPathComponent, duration: 1)
        }
        let urls = (0..<1500).map { URL(string: "pak://song/\($0)")! }
        for url in urls { _ = store.metadata(for: url) }
        for _ in 0..<600 where asked.count < urls.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked == urls)
        #expect(store.displayName(for: urls[1499]) == "1499")
    }

    @Test func retryingAsksAgainOnlyAboutTheMissing() async throws {
        let store = TrackInfoStore()
        var asked: [String] = []
        var answering = false
        store.loadExternal = { url in
            asked.append(url.lastPathComponent)
            return answering ? TrackMetadata(title: "T", duration: 1) : nil
        }
        let url = URL(string: "pak://song/1")!
        _ = store.metadata(for: url)
        try await Task.sleep(for: .milliseconds(50))
        answering = true
        store.retryMissing()
        _ = store.metadata(for: url)
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked == ["1", "1"])
        #expect(store.metadata(for: url)?.title == "T")
    }
}

@Suite struct NotesCachePruneTests {
    @Test func oldNotesAndThoseBeyondTheLimitAreDropped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BitampNotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func make(_ name: String, daysAgo: Double) throws {
            let url = folder.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
        }
        try make("new1.json", daysAgo: 1)
        try make("new2.json", daysAgo: 2)
        try make("new3.json", daysAgo: 3)
        try make("old.json", daysAgo: 200)
        try Data("x".utf8).write(to: folder.appendingPathComponent("keep.txt"))

        BackstoryCache.prune(folder, maxAge: 90 * 86400, maxFiles: 2, now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        // The two newest stay; the third is over the limit, the last is too old; other files are left alone.
        #expect(left == ["keep.txt", "new1.json", "new2.json"], "\(left)")
    }
}
