import AppKit
import Foundation
import Testing
@testable import BitampKit
@testable import BitampBackstory

// Everything here uses invented songs and canned replies; nothing goes over the network.

private let song = PakNowPlaying(title: "Dial-Up Sunrise", artist: "The Low Bits", album: "Low Tide FM")

/// Lines of a Messages API stream with web search, cut down: a search, then two text
/// blocks, the first citing two pages (one twice).
private let fixture = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","content":[],"usage":{"input_tokens":12}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"low bits dial-up sunrise\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"The Low Bits","url":"https://lowbits.example/history","encrypted_content":"x"}]}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://lowbits.example/history","title":"The Low Bits","encrypted_index":"y","cited_text":"recorded in eight days"}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"The band cut it in eight days"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://chipzine.example/low-tide-fm","title":"","encrypted_index":"z","cited_text":"a beach house"}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://lowbits.example/history","title":"The Low Bits","encrypted_index":"y","cited_text":"again"}}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: content_block_start
data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":" in a rented beach house."}}

event: content_block_stop
data: {"type":"content_block_stop","index":3}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40,"server_tool_use":{"web_search_requests":1}}}

event: message_stop
data: {"type":"message_stop"}
"""

@Suite struct ClaudeBackstoryTests {
    @Test func readsWordsAndEachBlocksSources() throws {
        var stream = ClaudeStream()
        var updates: [BackstoryUpdate] = []
        for line in fixture.components(separatedBy: "\n") { updates += try stream.feed(line) }
        try stream.finish()
        let history = BackstorySource(title: "The Low Bits", url: URL(string: "https://lowbits.example/history")!,
                                       quote: "recorded in eight days")
        // A citation without a title is named by its site.
        let zine = BackstorySource(title: "chipzine.example", url: URL(string: "https://chipzine.example/low-tide-fm")!,
                                    quote: "a beach house")
        #expect(updates == [.text("The band cut it in eight days"), .cite([history, zine]), .text(" in a rented beach house.")])
    }

    @Test func aRefusalAndAnErrorMidStreamAreErrors() throws {
        var refused = ClaudeStream()
        _ = try refused.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        #expect(throws: BackstoryError.declined) { try refused.finish() }

        var busy = ClaudeStream()
        #expect(throws: BackstoryError.unavailable("Claude is busy right now. Try again in a moment.")) {
            _ = try busy.feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    /// A paused turn isn't continued: what came is kept, and nothing at all is an error.
    @Test func aPausedTurnEndsWithWhatCame() throws {
        var partial = ClaudeStream()
        _ = try partial.feed(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Some words."}}"#)
        _ = try partial.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#)
        try partial.finish()

        var empty = ClaudeStream()
        _ = try empty.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#)
        #expect(throws: BackstoryError.self) { try empty.finish() }
    }

    @Test func errorsSayWhatToDo() {
        func error(_ status: Int, _ body: String) -> BackstoryError {
            ClaudeBackstory.error(status: status, body: Data(body.utf8))
        }
        #expect(error(401, #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) == .badKey)
        #expect(error(529, #"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .unavailable("Claude is busy right now. Try again in a moment."))
        #expect(error(400, #"{"error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#)
                == .limited("The Claude account is out of credit."))
        #expect(error(429, "") == .limited("Claude says there have been too many requests. Try again in a minute."))
    }

    /// Search is direct (dynamic filtering leaves the notes without citations), limited to
    /// two searches, and the request names only the song's tags.
    @Test func asksWithDirectSearch() throws {
        let body = ClaudeBackstory.body(for: song, model: .sonnet)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["stream"] as? Bool == true)
        let tool = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "web_search_20260318")
        #expect(tool["allowed_callers"] as? [String] == ["direct"])
        #expect(tool["max_uses"] as? Int == 2)
        #expect(ClaudeBackstory.body(for: song, model: .opus)["model"] as? String == "claude-opus-5-5")
        #expect(ClaudeBackstory.prompt(for: song) == #"Now playing: "Dial-Up Sunrise" by The Low Bits, from the album "Low Tide FM"."#)

        let request = ClaudeBackstory(key: "test-key").request(for: song)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    }
}

@Suite struct BackstoryTextTests {
    @Test func marksGoAfterTheCitedWordsAndNumbersAreReused() {
        let a = BackstorySource(title: "A", url: URL(string: "https://a.example")!)
        let b = BackstorySource(title: "B", url: URL(string: "https://b.example")!)
        var notes = BackstoryNotes()
        notes.apply(.text("First fact. "))
        notes.apply(.cite([a]))
        notes.apply(.text("Second fact.\n\n"))
        notes.apply(.cite([b, a]))
        notes.apply(.text("Third."))
        #expect(notes.text == "First fact. [1] Second fact. [2,1]\n\nThird.")
        #expect(notes.sources == [a, b])
    }

    @Test func punctuationIsMadePlain() {
        #expect(BackstoryNotes.plain("It\u{2019}s *Low Tide FM*\u{2014}\u{201C}great\u{201D}\u{2026}") == "It's Low Tide FM - \"great\"...")
    }

    @Test func aMarkStaysWithItsWord() {
        let line = "abcdefghij abcdefghij"
        let width = ListFont.width(of: line)
        #expect(BackstoryView.wrap(line + " [1]", width: width) == ["abcdefghij", "abcdefghij [1]"])
    }
}

/// Settings kept in memory, the key included.
final class BackstoryMemorySettings: PakSettingsStore {
    var secrets: [String: String] = [:]
    override func secret(_ pak: String, _ key: String) -> String? { secrets["\(pak).\(key)"] }
    override func setSecret(_ value: String?, _ pak: String, _ key: String) { secrets["\(pak).\(key)"] = value }
}

/// Answers every song with the same words, counting how often it's asked.
final class CannedBackstory: BackstoryService, @unchecked Sendable {
    var asked = 0
    var updates: [BackstoryUpdate] = [.text("Canned notes.")]

    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        asked += 1
        let updates = updates
        return AsyncThrowingStream { continuation in
            updates.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

@MainActor
@Suite struct BackstorySessionTests {
    let service = CannedBackstory()
    let pak: BackstoryPak
    var now: TimeInterval = 0
    let clock: Clock
    let session: BackstorySession
    let player = Player()

    final class Clock { var now: TimeInterval = 0 }
    final class Player {
        var url: URL? = URL(string: "bitpak-test://track/1")
        var playing = true
        var next: URL?
        var remaining: TimeInterval = 200
    }

    init() {
        let store = BackstoryMemorySettings(defaults: UserDefaults(suiteName: "BitampBackstory-\(UUID().uuidString)")!)
        let service = self.service
        pak = BackstoryPak(providers: [.init(name: "Claude", models: ["Sonnet 5.5", "Opus 5.5"]) { _, _ in service }], store: store)
        let clock = Clock()
        self.clock = clock
        session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil), clock: { clock.now })
        let player = self.player
        session.current = { (player.url, player.playing) }
        session.upcoming = { (player.next, player.remaining) }
        // Each track is its own song, except that "1-again" is track 1 once more.
        session.describe = { url in
            let name = url.lastPathComponent.replacingOccurrences(of: "-again", with: "")
            return (name == "untagged" ? nil : PakNowPlaying(title: "Song \(name)", artist: "The Low Bits", album: "Low Tide FM"), nil)
        }
    }

    /// Advances the clock a second at a time, updating as the window would.
    func run(seconds: Int, active: Bool = true) async {
        for _ in 0..<seconds {
            clock.now += 1
            session.update(active: active)
            await settle()
        }
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func start(lookup: BackstoryPak.Lookup, key: String? = "test-key") async {
        pak.save(["lookup": lookup.rawValue] .merging(key.map { ["claude-key": $0] } ?? [:]) { $1 })
        session.update(active: true)
        await settle()
    }

    @Test func nothingIsLookedUpByItselfAtFirst() {
        #expect(pak.lookup == .whenAsked)
        #expect(pak.account == .disconnected)
    }

    @Test func everyTrackWaitsForTwoSecondsOfPlaying() async {
        #expect(BackstorySession.delay == 2)
        await start(lookup: .everyTrack)
        #expect(session.phase == .waiting)
        await run(seconds: 1)
        player.playing = false
        await run(seconds: 10)
        #expect(service.asked == 0, "paused time doesn't count")
        player.playing = true
        await run(seconds: 1)
        #expect(service.asked == 1)
        #expect(session.phase == .done)
        #expect(session.notes.text == "Canned notes.")
    }

    @Test func nothingStartsWhileInactive() async {
        await start(lookup: .everyTrack)
        await run(seconds: 10, active: false)
        #expect(service.asked == 0)
        await run(seconds: 1)
        #expect(service.asked == 1)
    }

    @Test func skippingCancelsTheWait() async {
        await start(lookup: .everyTrack)
        await run(seconds: 1)
        player.url = URL(string: "bitpak-test://track/2")
        await run(seconds: 2)
        #expect(service.asked == 0)
        await run(seconds: 1)
        #expect(service.asked == 1)
    }

    @Test func savedNotesShowWithoutAsking() async {
        await start(lookup: .whenAsked)
        #expect(session.phase == .ready)
        session.lookUp()
        await settle()
        #expect(service.asked == 1)
        player.url = URL(string: "bitpak-test://track/1-again")
        await run(seconds: 10)
        #expect(session.phase == .done)
        #expect(service.asked == 1)
    }

    @Test func needsAKeyAndTags() async {
        await start(lookup: .everyTrack, key: nil)
        #expect(session.phase == .needsSetup)
        pak.save(["claude-key": "test-key"])
        session.settingsChanged()
        #expect(session.phase == .waiting)
        player.url = URL(string: "bitpak-test://track/untagged")
        await run(seconds: 10)
        #expect(session.phase == .untagged)
        #expect(service.asked == 0)
    }

    @Test func offLooksNothingUp() async {
        await start(lookup: .off)
        await run(seconds: 10)
        #expect(session.phase == .off)
        #expect(service.asked == 0)
    }

    @Test func aChangedModelHasItsOwnNotes() async {
        await start(lookup: .whenAsked)
        session.lookUp()
        await settle()
        let sonnet = pak.identity
        pak.save(["claude-model": "Opus 5.5"])
        #expect(pak.identity != sonnet)
        #expect(pak.account == .connected(name: "Claude Opus 5.5"))
    }
}

/// Holds every answer until released, as a slow service would.
final class GatedBackstory: BackstoryService, @unchecked Sendable {
    private(set) var asked: [String] = []
    private var waiting: [AsyncThrowingStream<BackstoryUpdate, Error>.Continuation] = []

    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        asked.append(track.title)
        return AsyncThrowingStream { waiting.append($0) }
    }

    func release() {
        for continuation in waiting {
            continuation.yield(.text("Gated notes."))
            continuation.finish()
        }
        waiting = []
    }
}

@MainActor
@Suite struct BackstoryEarlyTests {
    let service = GatedBackstory()
    let pak: BackstoryPak
    let session: BackstorySession
    let clock = BackstorySessionTests.Clock()
    let player = BackstorySessionTests.Player()

    init() {
        let store = BackstoryMemorySettings(defaults: UserDefaults(suiteName: "BitampBackstoryEarly-\(UUID().uuidString)")!)
        let service = self.service
        pak = BackstoryPak(providers: [.init(name: "Claude", models: ["Sonnet 5.5"]) { _, _ in service }], store: store)
        pak.save(["claude-key": "test-key", "lookup": BackstoryPak.Lookup.everyTrack.rawValue])
        let clock = self.clock, player = self.player
        session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil), clock: { clock.now })
        session.current = { (player.url, player.playing) }
        session.upcoming = { (player.next, player.remaining) }
        session.describe = { url in (PakNowPlaying(title: url.lastPathComponent, artist: "The Low Bits"), nil) }
        player.next = URL(string: "bitpak-test://track/2")
    }

    func run(seconds: Int) async {
        for _ in 0..<seconds {
            clock.now += 1
            session.update(active: true)
            for _ in 0..<20 { await Task.yield() }
        }
    }

    func release() async {
        service.release()
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func offByDefault() async {
        #expect(!pak.prefetch)
        player.remaining = 10
        await run(seconds: 5)
        await release()
        #expect(service.asked == ["1"])
    }

    @Test func looksUpTheNextSongNearTheEnd() async {
        pak.prefetch = true
        await run(seconds: 5)
        await release()
        #expect(service.asked == ["1"])
        player.remaining = 25
        await run(seconds: 1)
        #expect(service.asked == ["1"])
        player.remaining = 19
        await run(seconds: 3)
        #expect(service.asked == ["1", "2"], "once")
        await release()
        // When it starts, its notes are there.
        player.url = player.next
        player.next = URL(string: "bitpak-test://track/3")
        player.remaining = 200
        await run(seconds: 1)
        #expect(session.phase == .done)
        #expect(session.notes.text == "Gated notes.")
        #expect(service.asked == ["1", "2"])
    }

    @Test func aSongThatStartsMidLookupShowsItsNotesAsTheyCome() async {
        pak.prefetch = true
        await run(seconds: 3)
        await release()
        player.remaining = 10
        await run(seconds: 1)
        #expect(session.lookingUpEarly == player.next)
        player.url = player.next
        player.next = nil
        await run(seconds: 5)
        #expect(session.phase == .looking)
        await release()
        #expect(session.phase == .done)
        #expect(service.asked == ["1", "2"], "not asked twice")
    }

    @Test func skippingElsewhereStopsIt() async {
        pak.prefetch = true
        await run(seconds: 3)
        await release()
        player.remaining = 10
        await run(seconds: 1)
        #expect(session.lookingUpEarly != nil)
        player.url = URL(string: "bitpak-test://track/9")
        await run(seconds: 1)
        #expect(session.lookingUpEarly == nil)
    }

    @Test func onlyWithEveryTrack() async {
        pak.prefetch = true
        pak.lookup = .whenAsked
        player.remaining = 10
        await run(seconds: 5)
        #expect(service.asked.isEmpty)
    }
}

/// Fails every lookup with `error`, as a cloud service does with no network.
final class FailingBackstory: BackstoryService, @unchecked Sendable {
    let error: BackstoryError
    init(_ error: BackstoryError) { self.error = error }

    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        let error = error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

@MainActor
@Suite struct BackstoryOnDeviceTests {
    final class Model: @unchecked Sendable {
        var available = true
        let service = CannedBackstory()
    }
    let model = Model()

    func pak(cloud: BackstoryService = CannedBackstory(), onDevice: Bool = true) -> BackstoryPak {
        let store = BackstoryMemorySettings(defaults: UserDefaults(suiteName: "BitampBackstoryOnDevice-\(UUID().uuidString)")!)
        let model = self.model
        model.service.updates = [.text("On-device notes.")]
        return BackstoryPak(providers: [.init(name: "Claude", models: ["Sonnet 5.5"]) { _, _ in cloud }],
                            onDevice: onDevice ? .init(isAvailable: { model.available }, make: { model.available ? model.service : nil }) : nil,
                            store: store)
    }

    @Test func usedWithoutAKeyOrWhenChosen() {
        let pak = pak()
        #expect(pak.services == ["Claude", "On-device"])
        #expect(pak.choice()?.onDevice == true, "no key yet")
        #expect(pak.account == .connected(name: "On-device model"))
        pak.save(["claude-key": "test-key"])
        #expect(pak.choice()?.onDevice == false)
        pak.save(["service": BackstoryPak.onDeviceName])
        #expect(pak.choice()?.onDevice == true, "chosen")
        #expect(pak.choice()?.identity == "On-device")
    }

    @Test func notOfferedWhereItCantRun() {
        model.available = false
        let pak = pak()
        #expect(pak.choice() == nil)
        #expect(pak.account == .disconnected)
        #expect(self.pak(onDevice: false).services == ["Claude"])
    }

    @Test func answersWhenTheServiceCantBeReached() async {
        let pak = pak(cloud: FailingBackstory(.offline("Couldn't reach Claude")))
        pak.save(["claude-key": "test-key"])
        let session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil))
        session.current = { (URL(string: "bitpak-test://track/1"), true) }
        session.describe = { _ in (song, nil) }
        session.update(active: true)
        for _ in 0..<20 { await Task.yield() }
        session.lookUp()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.phase == .done)
        #expect(session.notes.text == "On-device notes.")
        #expect(session.notes.isOnDevice)
        #expect(model.service.asked == 1)
    }

    @Test func otherFailuresDontFallBack() async {
        let pak = pak(cloud: FailingBackstory(.badKey))
        pak.save(["claude-key": "test-key"])
        let session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil))
        session.current = { (URL(string: "bitpak-test://track/1"), true) }
        session.describe = { _ in (song, nil) }
        session.update(active: true)
        for _ in 0..<20 { await Task.yield() }
        session.lookUp()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.phase == .failed(BackstoryError.badKey.localizedDescription, badKey: true))
        #expect(model.service.asked == 0)
    }

    @Test func savedOnDeviceNotesKeepTheirMark() throws {
        var notes = BackstoryNotes()
        notes.apply(.text("Words."))
        notes.onDevice = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BitampBackstory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        BackstoryCache(folder: folder).save(notes, for: song, identity: "On-device")
        #expect(BackstoryCache(folder: folder).notes(for: song, identity: "On-device")?.isOnDevice == true)
        // Notes saved before the mark existed read as a cloud service's.
        let old = try JSONDecoder().decode(BackstoryNotes.self, from: Data(#"{"text":"Old.","sources":[]}"#.utf8))
        #expect(!old.isOnDevice)
    }
}

extension SnapshotTests {
    /// The Backstory window in each state, with invented notes.
    @Test func backstory() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var skins: [(String, Skin)] = [("default", DefaultSkin()), ("millennium", DefaultSkin(theme: .millennium))]
        if let path = ProcessInfo.processInfo.environment["BITAMP_SNAPSHOT_SKIN"] {
            skins.append(("wsz", try WszSkin(url: URL(fileURLWithPath: path))))
        }
        let service = CannedBackstory()
        service.updates = [
            .text("Dial-Up Sunrise opens Low Tide FM, the second album by The Low Bits. The band cut it in eight days in a rented beach house"),
            .cite([BackstorySource(title: "The Low Bits: a history", url: URL(string: "https://lowbits.example/history")!)]),
            .text(", and the squeal in the intro is a real modem handshake.\n\nIt was their first song on college radio"),
            .cite([BackstorySource(title: "Low Tide FM at ten", url: URL(string: "https://www.chipzine.example/low-tide-fm")!)]),
            .text("."),
        ]
        let onDevice = CannedBackstory()
        onDevice.updates = [.text("Dial-Up Sunrise is a song by The Low Bits from the album Low Tide FM. It mixes chiptune sounds with indie pop.")]
        for (name, skin) in skins {
            for state in ["setup", "ready", "notes", "on-device", "on-device-setup", "on-device-claude-setup"] {
                let store = BackstoryMemorySettings(defaults: UserDefaults(suiteName: "BitampBackstorySnap-\(UUID().uuidString)")!)
                let pak = BackstoryPak(providers: [.init(name: "Claude", models: ["Sonnet 5.5", "Opus 5.5"],
                                                          costs: ["Sonnet 5.5": "About 4 cents a song"]) { _, _ in service }],
                                        onDevice: state.hasPrefix("on-device") ? .init(isAvailable: { true }, make: { onDevice }) : nil,
                                        store: store)
                if !state.hasSuffix("setup") && !state.hasPrefix("on-device") { pak.save(["claude-key": "test-key"]) }
                let session = BackstorySession(pak: pak, cache: BackstoryCache(folder: nil))
                session.current = { (URL(string: "bitpak-test://track/1"), true) }
                session.describe = { _ in (song, showcaseCover(17, size: 96)) }
                let view = BackstoryView(session: session, paks: PakRegistry([pak]), skin: skin, scale: 2)
                session.update(active: true)
                for _ in 0..<50 { await Task.yield() }
                if state == "on-device-setup" {
                    pak.save(["service": BackstoryPak.onDeviceName])
                    view.showSetup()
                }
                if state == "on-device-claude-setup" { view.showSetup() }
                if state == "notes" || state == "on-device" {
                    session.lookUp()
                    for _ in 0..<50 { await Task.yield() }
                }
                try save(view, "\(name)-backstory-\(state)")
            }
        }
    }
}
