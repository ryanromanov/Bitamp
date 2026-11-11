import BitampPakProtocol
import BitampPakSDK
import Foundation
import Testing
@testable import BitampKit

/// A Pak's provider for testing the SDK's request loop without a process.
private final class EchoProvider: PakProvider {
    var settings: [String: String] = [:]

    func configure(_ context: PakContext) async throws -> PakAccountState {
        settings = context.settings
        return context.settings["token"] == nil ? PakAccountState(.disconnected, message: "No token") : .connected
    }

    func search(_ term: String) async throws -> [PakTrackInfo] {
        [PakTrackInfo(id: "1", title: "Found \(term)")]
    }

    func track(id: String) async throws -> PakTrackInfo? {
        id == "1" ? PakTrackInfo(id: "1", title: "One", duration: 60) : nil
    }

    func resolve(id: String) async throws -> PakSource {
        throw PakFailure("Can't play \(id)")
    }
}

/// Passwords in memory, so tests never touch the Keychain.
@MainActor
private final class MemorySettingsStore: PakSettingsStore {
    var secrets: [String: String] = [:]
    override func secret(_ pak: String, _ key: String) -> String? { secrets["\(pak).\(key)"] }
    override func setSecret(_ value: String?, _ pak: String, _ key: String) { secrets["\(pak).\(key)"] = value }
}

private final class Marker {}

@Suite struct PakRunnerTests {
    @Test func answersEachRequestOnItsOwnLine() async {
        let provider = EchoProvider()
        let requests = [
            #"{"id":1,"method":"hello","params":{"protocol":1,"settings":{"token":"abc"},"cacheDirectory":"/tmp/bitamp-pak-test"}}"#,
            #"{"id":2,"method":"search","params":{"term":"ode"}}"#,
            #"{"id":3,"method":"track","params":{"id":"nope"}}"#,
            #"{"id":4,"method":"resolve","params":{"id":"1"}}"#,
            "not json",
            #"{"id":5,"method":"shutdown","params":{}}"#,
            #"{"id":6,"method":"search","params":{"term":"after shutdown"}}"#,
        ]
        var replies: [String] = []
        await PakRunner.serve(provider, input: AsyncStream { continuation in
            requests.forEach { continuation.yield($0) }
            continuation.finish()
        }) { replies.append($0) }

        #expect(replies == [
            #"{"id":1,"result":{"account":{"state":"connected"}}}"#,
            #"{"id":2,"result":{"tracks":[{"id":"1","title":"Found ode"}]}}"#,
            #"{"id":3,"result":{}}"#,
            #"{"error":{"message":"Can't play 1"},"id":4}"#,
            #"{"id":5,"result":{}}"#,
        ])
        #expect(provider.settings == ["token": "abc"])
    }

    @Test func browsesWithASearchOnlyDefault() async {
        let requests = [
            #"{"id":1,"method":"browse","params":{"location":{"kind":"search","term":"ode"}}}"#,
            #"{"id":2,"method":"browse","params":{"location":{"kind":"root"}}}"#,
            #"{"id":3,"method":"browse","params":{"location":{"kind":"place","id":"albums"},"cursor":"2"}}"#,
        ]
        var replies: [String] = []
        await PakRunner.serve(EchoProvider(), input: AsyncStream { continuation in
            requests.forEach { continuation.yield($0) }
            continuation.finish()
        }) { replies.append($0) }
        #expect(replies == [
            #"{"id":1,"result":{"page":{"shelves":[{"items":[{"track":{"id":"1","title":"Found ode"}}]}]}}}"#,
            #"{"id":2,"result":{"page":{"shelves":[]}}}"#,
            #"{"error":{"message":"Nothing called albums here."},"id":3}"#,
        ])
    }
}

@Suite struct PakBrowseWireTests {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func locationsArePlainObjects() throws {
        #expect(try encode(PakBrowseLocation.root) == #"{"kind":"root"}"#)
        #expect(try encode(PakBrowseLocation.place("a b")) == #"{"id":"a b","kind":"place"}"#)
        #expect(try encode(PakBrowseLocation.search("ode")) == #"{"kind":"search","term":"ode"}"#)
        #expect(try decode(PakBrowseLocation.self, #"{"kind":"search"}"#) == .search(""))
        #expect(throws: DecodingError.self) { try decode(PakBrowseLocation.self, #"{"kind":"genre"}"#) }
    }

    @Test func aPageReadsLeniently() throws {
        let page = try decode(PakBrowsePage.self, """
        {"header":{"title":"Low Tide FM","subtitle":"The Low Bits","artwork":{"url":"https://covers.example/1.jpg"}},
         "shelves":[{"title":"Songs","items":[
            {"track":{"id":"t1","title":"Dial-Up Sunrise","artwork":{"file":"/tmp/cover.png"}}},
            {"video":{"id":"v1"}},
            {"place":{"kind":"genre","id":"g1","title":"Chiptune"}}]}],
         "cursor":"next","future":"ignored"}
        """)
        #expect(page.header?.artwork == .url(URL(string: "https://covers.example/1.jpg")!))
        #expect(page.shelves[0].items.count == 2, "an item type this version doesn't know is left out")
        #expect(page.shelves[0].items[1] == .place(PakPlaceInfo(kind: "genre", id: "g1", title: "Chiptune")))
        #expect(page.cursor == "next")
        #expect(try decode(PakBrowsePage.self, "{}").shelves.isEmpty)
    }

    @Test func aManifestListsWhatThePakCan() throws {
        let manifest = try decode(PakManifest.self, """
        {"id":"radio","name":"Radio","version":"1","executable":"run","protocol":1,"capabilities":["browse","lyrics"]}
        """)
        #expect(manifest.can(PakProtocol.browse))
        #expect(!manifest.can("companion"))
        #expect(try decode(PakManifest.self, #"{"id":"radio","name":"Radio","version":"1","executable":"run","protocol":1}"#).capabilities == nil)
    }
}

@MainActor @Suite struct PakLibraryTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("BitampPaks-\(UUID().uuidString)")

    /// A `.bitpak` folder with `manifest` and, unless `program` is nil, a program.
    private func makePak(_ name: String, _ manifest: String, program: String? = "#!/bin/sh\nexit 0\n") throws -> URL {
        let folder = root.appendingPathComponent("source/\(name).bitpak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("pak.json"), atomically: true, encoding: .utf8)
        if let program {
            let file = folder.appendingPathComponent("run")
            try program.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return folder
    }

    private func manifest(id: String = "radio", executable: String = "run", protocol: Int = 1) -> String {
        #"{"id":"\#(id)","name":"Radio","version":"1.0","executable":"\#(executable)","protocol":\#(`protocol`),"#
            + #""settings":[{"key":"server","label":"Server","type":"text"},{"key":"password","label":"Password","type":"password"}]}"#
    }

    @Test func checksManifests() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try PakLibrary.manifest(in: makePak("good", manifest())).id == "radio")
        #expect(throws: PakLibrary.InstallError.self) { try PakLibrary.manifest(in: makePak("id", manifest(id: "Bad ID"))) }
        #expect(throws: PakLibrary.InstallError.self) { try PakLibrary.manifest(in: makePak("newer", manifest(protocol: 99))) }
        #expect(throws: PakLibrary.InstallError.self) { try PakLibrary.manifest(in: makePak("none", manifest(), program: nil)) }
        // The program has to be inside the folder.
        #expect(throws: PakLibrary.InstallError.self) { try PakLibrary.manifest(in: makePak("escape", manifest(executable: "../../../bin/sh"))) }
        #expect(throws: PakLibrary.InstallError.self) { try PakLibrary.manifest(in: makePak("empty", "{}")) }
        #expect(PakManifest.isValidID("demo") && PakManifest.isValidID("my-pak2"))
        #expect(!PakManifest.isValidID("2pak") && !PakManifest.isValidID("") && !PakManifest.isValidID("a_b"))
    }

    @Test func installsReplacesAndRemoves() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = MemorySettingsStore(defaults: UserDefaults(suiteName: "BitampPakLibrary-\(UUID().uuidString)")!)
        let library = PakLibrary(folder: root.appendingPathComponent("installed"), settings: settings)
        let source = try makePak("Radio", manifest())

        try library.install(source, reservedIDs: ["builtin"])
        var installed = library.installed()
        #expect(installed.map(\.id) == ["radio"])
        #expect(installed[0].folder.lastPathComponent == "radio.bitpak")
        #expect(installed[0].isAvailable)

        // Settings: plain ones in defaults, the password in the "Keychain".
        settings.save(["server": "https://music.example", "password": "hunter2"], for: installed[0].manifest)
        #expect(settings.values(for: installed[0].manifest) == ["server": "https://music.example", "password": "hunter2"])
        #expect(settings.secrets == ["radio.password": "hunter2"])

        // Same id again: an update in place.
        try library.install(source, reservedIDs: [])
        #expect(library.installed().count == 1)
        #expect(throws: PakLibrary.InstallError.self) { try library.install(source, reservedIDs: ["radio"]) }

        // The installed copy itself, as if dragged from the Paks folder: left as it is.
        let copy = library.installed()[0].folder
        #expect(library.contains(copy))
        #expect(!library.contains(source))
        try library.install(copy, reservedIDs: [])
        #expect(library.installed().map(\.id) == ["radio"])
        #expect(library.installed()[0].isAvailable)

        installed = library.installed()
        try library.remove(installed[0])
        #expect(library.installed().isEmpty)
        #expect(settings.values(for: installed[0].manifest).isEmpty)
    }

    @Test func trackURLsRoundTrip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pak = ExternalPak(manifest: try PakLibrary.manifest(in: makePak("Radio", manifest())),
                              folder: try makePak("Radio", manifest()), settings: MemorySettingsStore())
        for id in ["1", "song 1", "a/b?c#d", "ünï"] {
            let url = pak.trackURL(id)
            #expect(url.scheme == "bitpak-radio")
            #expect(pak.trackID(url) == id)
        }
        #expect(pak.trackID(URL(string: "bitpak-other://track/1")!) == nil)
    }

    @Test func aPakThatKeepsCrashingIsGivenUpOn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makePak("Crash", manifest(), program: "#!/bin/sh\nexit 3\n")
        let pak = ExternalPak(manifest: try PakLibrary.manifest(in: folder), folder: folder, settings: MemorySettingsStore())
        var errors: [String] = []
        for _ in 0..<5 {
            do {
                _ = try await pak.search("x")
            } catch {
                errors.append(error.localizedDescription)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(errors.count == 5)
        #expect(errors.last == PakConnection.Failure.keepsCrashing.localizedDescription)
    }

    @Test func theCheckCatchesStrayOutput() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Answers hello and search by their ids (1 and 2), with a debugging line in between.
        let program = """
            #!/bin/sh
            read line; echo '{"id":1,"result":{"account":{"state":"connected"}}}'
            read line; echo "searching"; echo '{"id":2,"result":{"tracks":[]}}'
            read line

            """
        var lines: [String] = []
        let check = PakCheck(folder: try makePak("Chatty", manifest(), program: program)) { lines.append($0) }
        #expect(await check.run() == false)
        #expect(check.problems == 1)
        #expect(lines.contains { $0.hasPrefix("✗ It printed a line that isn't an answer: searching") })
        #expect(lines.contains("✓ shutdown: exited"))
    }
}

/// The demo Pak's real program, run by the host as Bitamp runs it.
@MainActor @Suite struct DemoPakTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("BitampDemoPak-\(UUID().uuidString)")

    /// Demo.bitpak, put together from the test build's program and the manifest.
    private func demoFolder() throws -> URL {
        let program = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BitampDemoPak")
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/BitampDemoPak/pak.json").standardizedFileURL
        let folder = root.appendingPathComponent("Demo.bitpak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifest, to: folder.appendingPathComponent("pak.json"))
        try FileManager.default.copyItem(at: program, to: folder.appendingPathComponent("demo-pak"))
        return folder
    }

    /// The demo, installed in a library of its own.
    private func demoPak() throws -> ExternalPak {
        let folder = try demoFolder()
        let library = PakLibrary(folder: root.appendingPathComponent("installed"), settings: MemorySettingsStore(
            defaults: UserDefaults(suiteName: "BitampDemoPak-\(UUID().uuidString)")!))
        try library.install(folder, reservedIDs: [])
        return try #require(library.installed().first)
    }

    @Test func passesTheCheck() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        let check = PakCheck(folder: try demoFolder(), reservedIDs: ["applemusic"]) { lines.append($0) }
        #expect(await check.run(), "\(lines.joined(separator: "\n"))")
        #expect(lines.first == "✓ pak.json: Demo Pak 1.0, id “demo”, runs demo-pak")
        #expect(lines.contains("✓ track “ode-to-joy”: “Ode to Joy”"))
        #expect(lines.last == "The Demo Pak looks good. Double-click it to install it.")
    }

    @Test func browsesTheMediaLibrary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pak = try demoPak()
        defer { pak.disconnect() }
        #expect(pak.canBrowse)
        let root = try await pak.browse(.root, after: nil)
        #expect(root.shelves.first?.title == "Demo")
        #expect(root.shelves.first?.items.compactMap(\.place).map(\.title) == ["All Tunes", "Composers", "Albums", "Playlists"])

        // Four, then the rest after the cursor, as PLAY and ADD take them.
        let first = try await pak.browse(.place("tunes"), after: nil)
        #expect(first.tracks.count == 4 && first.cursor == "4")
        let all = try await pak.allTracks(at: .place("tunes"))
        #expect(all.count == 6)
        #expect(all[0].url.absoluteString == "bitpak-demo://track/ode-to-joy")

        let albums = try await pak.browse(.place("albums"), after: nil)
        let album = try #require(albums.shelves.first?.items.first?.place)
        #expect(album.kind == .album && album.title == "Beethoven Bits")
        let page = try await pak.browse(.place(album.id), after: nil)
        #expect(page.header?.subtitle == "Ludwig van Beethoven")
        #expect(page.tracks.map(\.title) == ["Ode to Joy", "Für Elise"])

        // Covers are the Pak's files.
        let artwork = try #require(album.artwork)
        #expect(URL(string: artwork.id)?.isFileURL == true)
        let image = try #require(await pak.image(for: artwork, size: 64))
        #expect(image.width == 64)

        await #expect(throws: (any Error).self) { try await pak.browse(.place("nowhere"), after: nil) }
    }

    @Test func searchesLooksUpAndPlays() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pak = try demoPak()
        defer { pak.disconnect() }
        #expect(pak.name == "Demo" && pak.hasSettings)

        let everything = try await pak.search("")
        #expect(everything.count == 6)
        let beethoven = try await pak.search("beethoven")
        #expect(beethoven.map(\.title) == ["Ode to Joy", "Für Elise"])
        let ode = beethoven[0]
        #expect(ode.url.absoluteString == "bitpak-demo://track/ode-to-joy")
        #expect(await pak.metadata(for: ode.url)?.artist == "Ludwig van Beethoven")

        // Played through the controller: fetched, then loaded into the engine under its title.
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampDemoPlay-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak]))
        controller.info.seed(TrackMetadata(title: ode.title, artist: ode.artist, duration: ode.duration), for: ode.url)
        controller.setQueueItems([ode.url])
        controller.playItem(at: 0)
        #expect(controller.fetching == ode.url)
        for _ in 0..<200 where controller.fetching != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(controller.fetching == nil)
        let track = try #require(controller.engine.track)
        #expect(track.title == "Ode to Joy" && track.artist == "Ludwig van Beethoven")
        #expect(abs(track.duration - (ode.duration ?? 0)) < 0.1)
        #expect(controller.player === controller.engine)
        #expect(controller.playingPak === pak)
        #expect(controller.limitation(.equalizer) == nil)
        controller.stop()

        // A new waveform renders a new file.
        try await pak.configure(["waveform": "Sawtooth"])
        let sawtooth = try await pak.search("joy")
        #expect(sawtooth.count == 1)
        #expect(FileManager.default.fileExists(atPath: pak.cacheDirectory.appendingPathComponent("ode-to-joy-square.wav").path))
    }
}
