import AppKit
import AVFoundation
import Foundation
import Testing
@testable import BitampAppleMusicPak
@testable import BitampKit

/// A Pak whose tracks are `fake://song/<n>` and that plays them on its own backend, as a
/// streaming service's own player would.
@MainActor
private final class FakePak: Pak {
    let id = "fake"
    let name = "Fake"
    let schemes: Set<String> = ["fake"]
    var isAvailable = true
    var account = PakAccount.connected(name: nil)
    let backend = FakeBackend()
    private(set) var lookups = 0

    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }

    func metadata(for url: URL) async -> PakTrack? {
        lookups += 1
        return PakTrack(url: url, title: "Song \(url.lastPathComponent)", artist: "Fake Artist", duration: 180)
    }

    func playback(for url: URL) throws -> PakPlayback {
        guard url.host == "song" else { throw CocoaError(.fileReadUnsupportedScheme) }
        return .backend(backend)
    }
}

/// One of many Paks, for filling the Expansion Paks window.
@MainActor
private final class ShelfPak: Pak {
    let id: String
    var name: String { id.uppercased() }
    var schemes: Set<String> { [id] }
    let isAvailable = true
    let account = PakAccount.connected(name: nil)

    init(id: String) {
        self.id = id
    }

    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.fileReadUnsupportedScheme) }
}

@MainActor
private final class FakeBackend: PlaybackBackend {
    private(set) var state = PlaybackState.stopped
    private(set) var nowPlaying: NowPlaying?
    var currentTime: Double = 0
    let capabilities: PlaybackCapabilities = []
    var onTrackEnd: (() -> Void)?
    var onLoadFailure: ((Error) -> Void)?
    private(set) var loaded: [URL] = []

    func load(_ url: URL) throws {
        stop()
        loaded.append(url)
        nowPlaying = NowPlaying(url: url, title: url.lastPathComponent, duration: 180)
    }

    func play() { if nowPlaying != nil { state = .playing } }
    func pause() { state = state == .playing ? .paused : state == .paused ? .playing : .stopped }
    func stop() { state = .stopped }
    func seek(to seconds: Double) { currentTime = seconds }

    func finish() {
        stop()
        onTrackEnd?()
    }

    /// Like a song whose lookup failed after `load` returned.
    func failLater() {
        stop()
        onLoadFailure?(CocoaError(.fileReadUnknown))
    }
}

@MainActor @Suite struct PakTests {
    private let one = URL(string: "fake://song/1")!
    private let two = URL(string: "fake://song/2")!

    private func controller(_ pak: FakePak) -> PlaybackController {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampPaks-\(UUID().uuidString)")!)
        return PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak]))
    }

    /// A one-second tone, so the engine has a real file to load.
    private func toneFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pak-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.06) * 0.2 }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    @Test func registryFindsThePakByScheme() {
        let pak = FakePak()
        let registry = PakRegistry([pak])
        #expect(registry.pak(for: one) === pak)
        #expect(registry.pak(for: URL(string: "FAKE://song/1")!) === pak)
        #expect(registry.pak(for: URL(string: "other://song/1")!) == nil)
        #expect(registry.schemes == ["fake"])
        pak.isAvailable = false
        #expect(registry.pak(for: one) == nil)
        #expect(registry.schemes.isEmpty)
    }

    @Test func pakTracksPlayOnThePaksBackend() {
        let pak = FakePak()
        let controller = controller(pak)
        controller.enqueue([one, two])
        #expect(controller.player === pak.backend)
        #expect(pak.backend.loaded == [one])
        #expect(pak.backend.state == .playing)

        pak.backend.finish()
        #expect(pak.backend.loaded == [one, two])
        #expect(controller.queue.currentIndex == 1)
        #expect(pak.backend.state == .playing)
    }

    @Test func switchingBetweenAFileAndAPakTrackStopsTheOtherBackend() throws {
        let pak = FakePak()
        let controller = controller(pak)
        let file = try toneFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.setQueueItems([one, file])
        controller.playItem(at: 0)
        #expect(controller.player === pak.backend)

        controller.playItem(at: 1)
        #expect(controller.player === controller.engine)
        #expect(pak.backend.state == .stopped)
        #expect(controller.engine.track?.url == file)

        controller.playItem(at: 0)
        #expect(controller.player === pak.backend)
        #expect(controller.engine.state == .stopped)
        controller.engine.stop()
    }

    @Test func tracksNoPakCanPlayAreSkipped() {
        let pak = FakePak()
        let controller = controller(pak)
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.setQueueItems([URL(string: "fake://album/9")!, URL(string: "other://song/1")!, two])
        controller.playItem(at: 0)
        #expect(pak.backend.loaded == [two])
        #expect(errors == ["CAN'T OPEN 9 (+1 MORE SKIPPED)"])
    }

    @Test func tracksThatFailAfterLoadingAreSkipped() {
        let pak = FakePak()
        let controller = controller(pak)
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.enqueue([one, two])
        pak.backend.failLater()
        #expect(pak.backend.loaded == [one, two])
        #expect(pak.backend.state == .playing)
        #expect(errors.count == 1)
    }

    /// With repeat on and every track failing, the skipping stops after one time around.
    @Test func skippingStopsWhenEveryTrackFails() {
        let pak = FakePak()
        let controller = controller(pak)
        controller.repeats = true
        controller.enqueue([one, two])
        for _ in 0..<5 where pak.backend.state == .playing { pak.backend.failLater() }
        #expect(pak.backend.loaded == [one, two])
        #expect(pak.backend.state == .stopped)
    }

    @Test func ejectingIsSavedAndStopsThePakThatsPlaying() {
        let defaults = UserDefaults(suiteName: "BitampPakEject-\(UUID().uuidString)")!
        let pak = FakePak()
        let controller = PlaybackController(
            engine: PlayerEngine(), preferences: Preferences(defaults: defaults),
            paks: PakRegistry([pak], preferences: Preferences(defaults: defaults)))
        controller.enqueue([one])
        #expect(controller.playingPak === pak)
        controller.setInserted(false, pak)
        #expect(pak.backend.state == .stopped)
        #expect(controller.paks.pak(for: one) == nil)
        #expect(controller.paks.owner(of: one) === pak)
        // Its tracks stay in playlists, and the next launch remembers it's out.
        #expect(controller.paks.schemes == ["fake"])
        #expect(!PakRegistry([FakePak()], preferences: Preferences(defaults: defaults)).isInserted(pak))
    }

    @Test func anEjectedPaksTracksAreSkipped() throws {
        let pak = FakePak()
        let controller = controller(pak)
        let file = try toneFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.paks.setInserted(false, pak)
        controller.setQueueItems([one, file])
        controller.playItem(at: 0)
        #expect(pak.backend.loaded.isEmpty)
        #expect(controller.engine.track?.url == file)
        #expect(errors == ["Fake PAK IS EJECTED"])
        controller.engine.stop()
    }

    @Test func aRunOfSkippedTracksIsReportedOnce() throws {
        let pak = FakePak()
        let controller = controller(pak)
        let file = try toneFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.paks.setInserted(false, pak)
        controller.setQueueItems([one, two, URL(string: "fake://song/3")!, file])
        controller.playItem(at: 0)
        #expect(controller.engine.track?.url == file)
        #expect(errors == ["Fake PAK IS EJECTED"])
        controller.engine.stop()

        // Nothing playable at all: still one message.
        errors = []
        controller.setQueueItems([one, URL(fileURLWithPath: "/nowhere/gone.mp3"), two])
        controller.playItem(at: 0)
        #expect(errors == ["Fake PAK IS EJECTED (+2 MORE SKIPPED)"])
    }

    /// Quit with the Pak ejected and reopen: the playlist shows the titles it saved, and
    /// the ejected Pak is never asked. Inserting it fills in anything that was missing.
    @Test func savedTitlesShowWithoutAskingAnEjectedPak() async throws {
        let first = FakePak()
        let before = controller(first)
        before.setQueueItems([one, two])
        before.info.seed(TrackMetadata(title: "Fake Artist - Song 1", duration: 180), for: one)
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("pak-\(UUID().uuidString).m3u8")
        defer { try? FileManager.default.removeItem(at: list) }
        try before.savePlaylist(to: list)

        let pak = FakePak()
        let after = controller(pak)
        after.paks.setInserted(false, pak)
        after.loadPlaylist(list)
        #expect(after.queue.items == [one, two])
        #expect(after.info.displayName(for: one) == "Fake Artist - Song 1")
        #expect(after.info.duration(for: one) == 180)
        // Song 2's info hadn't loaded when it was saved, so it shows its ID for now.
        #expect(after.info.displayName(for: two) == "2")
        try await Task.sleep(for: .milliseconds(100))
        #expect(pak.lookups == 0)
        #expect(after.info.displayName(for: two) == "2")

        after.setInserted(true, pak)
        for _ in 0..<100 where after.info.metadata(for: two) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(after.info.displayName(for: two) == "Fake Artist - Song 2")
        #expect(pak.lookups == 1)
    }

    @Test func controlsAPakKeepsOutSayWhy() throws {
        let pak = FakePak()
        let controller = controller(pak)
        let file = try toneFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.setQueueItems([file, one])
        controller.playItem(at: 0)
        #expect(controller.limitation(.volume) == nil)
        #expect(controller.limitation(.equalizer) == nil)
        controller.playItem(at: 1)
        #expect(controller.limitation(.volume) == "Fake PLAYS AT YOUR MAC'S VOLUME")
        #expect(controller.limitation(.equalizer) == "THE EQ CAN'T REACH Fake")
        #expect(controller.limitation(.retroSound) == "RETRO SOUND CAN'T REACH Fake")
        // Still true while stopped: the Pak's track is the one loaded.
        controller.player.stop()
        #expect(controller.limitation(.volume) != nil)
    }

    @Test func paksWindowStopsGrowingAtTheScreen() {
        // Three to a row, 116 pixels for the first and 84 for each after.
        #expect(PakLayout.size(for: 3).height == 116)
        #expect(PakLayout.size(for: 10).height == 368)
        #expect(PakLayout.size(for: 10, maxRows: 2).height == 200)
        #expect(PakLayout.size(for: 1, maxRows: 0).height == 116)
        // A screen 700 pixels tall fits 7 rows (620), not 8 (704); a tiny one still gets one.
        #expect(PakLayout.rowsThatFit(700) == 7)
        #expect(PakLayout.rowsThatFit(704) == 8)
        #expect(PakLayout.rowsThatFit(50) == 1)
        #expect(PakLayout.rowsThatFit(PakLayout.size(for: 10, maxRows: 2).height) == 2)
    }

    @Test func paksWindowFitsBelowItsTop() {
        // Nothing to fit without a display.
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampPaks-\(UUID().uuidString)")!)
        let paks = PakRegistry((1...30).map { ShelfPak(id: "pak-\($0)") })
        let view = PakView(controller: PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: paks),
                           skin: DefaultSkin(), scale: 2)
        let window = SkinnedWindow(view: view, layoutName: "PaksTest", isMain: false)

        // Halfway down the screen, as under the playlist: it stops at the bottom.
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX, y: screen.midY))
        #expect(window.frame.minY >= screen.minY)
        #expect(abs(window.frame.maxY - screen.midY) <= 1)
        let low = window.frame.height

        // Moved to the top, it grows into the room.
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX, y: screen.maxY))
        #expect(window.frame.minY >= screen.minY)
        #expect(window.frame.height > low)
    }

    @Test func labelsSplitByWords() {
        #expect(PakView.labelLines("APPLE MUSIC", width: 49) == ["APPLE", "MUSIC"])
        #expect(PakView.labelLines("NAVIDROME", width: 49) == ["NAVIDROME"])
        #expect(PakView.labelLines("INTERNET RADIO DIRECTORY", width: 49) == ["INTERNET", "RADIO"])
    }

    @Test func pakTracksSurviveTheSessionPlaylist() throws {
        let pak = FakePak()
        let controller = controller(pak)
        let file = try toneFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.setQueueItems([one, file, two])
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("pak-\(UUID().uuidString).m3u8")
        defer { try? FileManager.default.removeItem(at: list) }
        try controller.savePlaylist(to: list)
        #expect(try String(contentsOf: list, encoding: .utf8).contains("\nfake://song/1\n"))

        #expect(AudioFiles.expand([list], schemes: ["fake"]) == [one, file, two])
        // Without the Pak its tracks drop out, as missing files do.
        #expect(AudioFiles.expand([list]) == [file])
    }

    @Test func removingMissingFilesKeepsPakTracks() {
        let controller = controller(FakePak())
        controller.setQueueItems([one, URL(fileURLWithPath: "/nowhere/gone.mp3"), two])
        controller.removeMissingFiles()
        #expect(controller.queue.items == [one, two])
    }

    @Test func playlistTitlesComeFromThePak() async throws {
        let controller = controller(FakePak())
        #expect(controller.info.displayName(for: one) == "1")
        for _ in 0..<100 where controller.info.metadata(for: one) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.info.displayName(for: one) == "Fake Artist - Song 1")
        #expect(controller.info.duration(for: one) == 180)
    }
}

@Suite struct AppleMusicURLTests {
    @Test func roundTrips() {
        for reference in [
            AppleMusicURL(source: .library, id: "i.JR6ot3zOR1O"),
            AppleMusicURL(source: .library, id: "-7499768453939934178"),
            AppleMusicURL(source: .catalog, id: "1440857781"),
        ] {
            #expect(AppleMusicURL(reference.url) == reference)
        }
        #expect(AppleMusicURL(source: .catalog, id: "1440857781").url.absoluteString == "applemusic://catalog/song/1440857781")
    }

    @Test func rejectsOtherURLs() {
        for text in ["applemusic://catalog/album/1", "applemusic://radio/song/1", "applemusic://catalog/song/",
                     "fake://catalog/song/1", "file:///catalog/song/1"] {
            #expect(AppleMusicURL(URL(string: text)!) == nil, "\(text)")
        }
    }
}
