import BitampPakProtocol
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A third-party Pak: a `.bitpak` folder whose program Bitamp runs and talks to (see
/// `PakConnection`). Its tracks are `bitpak-<id>://track/<the Pak's id>`; they play through
/// Bitamp's engine, so the equalizer, visualizer and Retro Sound all work.
///
/// A Pak whose manifest lists `notes` is a companion instead: it has no music, and writes
/// about the song that's playing in a window of its own.
@MainActor
final class ExternalPak: NotesPak {
    let manifest: PakManifest
    /// The installed `.bitpak` folder.
    let folder: URL
    private let settings: PakSettingsStore
    /// Bitamp's own settings for a notes Pak (when to look up), kept apart from the Pak's.
    private let defaults: UserDefaults
    private lazy var connection = PakConnection(
        executable: folder.appendingPathComponent(manifest.executable), name: manifest.name,
        hello: { [unowned self] in
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return (PakMethod.hello, PakMethod.Hello(
                protocol: PakProtocol.version, settings: settings.values(for: manifest),
                cacheDirectory: cacheDirectory.path))
        })
    private var lastAccount: PakAccountState? {
        didSet { if lastAccount != oldValue { onChange?() } }
    }
    /// Called when what the Pak says about itself changes, as after its settings are saved.
    var onChange: (() -> Void)?
    /// Headers for covers that need them, by the cover's id. Kept out of the id, which the
    /// cover cache stores, so a changing token doesn't miss the cache or get saved.
    private var artworkHeaders: [String: [String: String]] = [:]

    init(manifest: PakManifest, folder: URL, settings: PakSettingsStore, defaults: UserDefaults = .standard) {
        self.manifest = manifest
        self.folder = folder
        self.settings = settings
        self.defaults = defaults
        connection.onHello = { [weak self] result in self?.lastAccount = result.account }
    }

    var id: String { manifest.id }
    var name: String { manifest.name }
    var schemes: Set<String> { [Self.scheme(for: manifest.id)] }

    static func scheme(for id: String) -> String { "bitpak-\(id)" }

    var isAvailable: Bool {
        manifest.protocol <= PakProtocol.version
            && FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent(manifest.executable).path)
    }

    /// What the Pak said when it last started or was configured. Before it has run at all,
    /// a Pak with settings counts as needing them and one without as ready.
    var account: PakAccount {
        guard let lastAccount else { return hasSettings && settings.values(for: manifest).isEmpty ? .disconnected : .connected(name: nil) }
        switch lastAccount.state {
        case .connected: return .connected(name: lastAccount.message)
        case .disconnected: return .disconnected
        case .limited: return .limited(reason: lastAccount.message ?? "")
        }
    }

    /// Where the Pak keeps files, and where Bitamp puts what it downloads for it.
    var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ryanromanov.Bitamp/Paks/\(manifest.id)", isDirectory: true)
    }

    func connect() async throws {
        _ = try await connection.request(PakMethod.configure, PakMethod.Configure(settings: settings.values(for: manifest)),
                                         as: PakMethod.AccountResult.self)
    }

    /// Saves new settings and passes them on.
    func configure(_ values: [String: String]) async throws {
        settings.save(values, for: manifest)
        let result = try await connection.request(
            PakMethod.configure, PakMethod.Configure(settings: settings.values(for: manifest)), as: PakMethod.AccountResult.self)
        lastAccount = result.account
    }

    func settingValues() -> [String: String] {
        settings.values(for: manifest)
    }

    func disconnect() {
        connection.shutdown()
    }

    func search(_ term: String) async throws -> [PakTrack] {
        let result = try await connection.request(PakMethod.search, PakMethod.Search(term: term), as: PakMethod.SearchResult.self)
        return result.tracks.map(track)
    }

    func metadata(for url: URL) async -> PakTrack? {
        guard let trackID = trackID(url),
              let result = try? await connection.request(PakMethod.track, PakMethod.TrackID(id: trackID), as: PakMethod.TrackResult.self)
        else { return nil }
        return result.track.map(track)
    }

    func playback(for url: URL) throws -> PakPlayback {
        guard let trackID = trackID(url) else { throw PakConnection.Failure.pak("\(url) isn't one of the \(name) Pak's tracks.") }
        return .fetch { [self] in try await audio(for: trackID) }
    }

    /// A local file with the track's audio: the Pak's own, or downloaded from the URL it gives.
    private func audio(for trackID: String) async throws -> URL {
        let source = try await connection.request(PakMethod.resolve, PakMethod.TrackID(id: trackID), as: PakMethod.ResolveResult.self).source
        if let path = source.file {
            let file = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw PakConnection.Failure.pak("The \(name) Pak's file for this track is missing.")
            }
            return file
        }
        guard let text = source.url, let remote = URL(string: text), ["http", "https"].contains(remote.scheme?.lowercased()) else {
            throw PakConnection.Failure.pak("The \(name) Pak gave no audio for this track.")
        }
        return try await download(remote, headers: source.headers ?? [:])
    }

    /// Downloads into the Pak's cache, named by the URL, and reuses it next time.
    private func download(_ remote: URL, headers: [String: String]) async throws -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let pathExtension = remote.pathExtension.isEmpty ? "audio" : remote.pathExtension
        let file = folder.appendingPathComponent(String(digest.prefix(32))).appendingPathExtension(pathExtension)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var request = URLRequest(url: remote)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PakConnection.Failure.pak("Downloading from the \(name) Pak failed (HTTP \(http.statusCode)).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    func trackURL(_ trackID: String) -> URL { Self.trackURL(trackID, pak: manifest.id) }

    func trackID(_ url: URL) -> String? { Self.trackID(url, pak: manifest.id) }

    static func trackURL(_ trackID: String, pak: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme(for: pak)
        components.host = "track"
        components.path = "/" + trackID
        return components.url!
    }

    static func trackID(_ url: URL, pak: String) -> String? {
        guard url.scheme?.lowercased() == scheme(for: pak), url.host == "track" else { return nil }
        let id = String(url.path.dropFirst())
        return id.isEmpty ? nil : id
    }

    private func track(_ info: PakTrackInfo) -> PakTrack {
        PakTrack(url: trackURL(info.id), title: info.title, artist: info.artist, album: info.album, duration: info.duration,
                 artwork: info.artwork.flatMap(artwork))
    }

    // MARK: - Browsing

    /// Whether its manifest says it browses. Read before the Pak has run, so it can't come
    /// from the Pak itself.
    var canBrowse: Bool { manifest.can(PakProtocol.browse) && !writesNotes }

    func browse(_ location: PakLocation, after cursor: String?) async throws -> PakPage {
        guard canBrowse else {
            // As any Pak that only searches.
            if case .search(let term) = location {
                return cursor == nil ? PakPage(shelves: [PakShelf(items: try await search(term).map(PakItem.track))]) : PakPage()
            }
            if case .place(let id) = location { throw PakBrowseError.notFound(id) }
            return PakPage()
        }
        let wire: PakBrowseLocation = switch location {
        case .root: .root
        case .place(let id): .place(id)
        case .search(let term): .search(term)
        }
        let page = try await connection.request(PakMethod.browse, PakMethod.Browse(location: wire, cursor: cursor),
                                                as: PakMethod.BrowseResult.self).page
        return self.page(page)
    }

    func page(_ page: PakBrowsePage) -> PakPage {
        PakPage(
            header: page.header.map { PakHeader(title: $0.title, subtitle: $0.subtitle, detail: $0.detail, artwork: $0.artwork.flatMap(artwork)) },
            shelves: page.shelves.map { shelf in
                PakShelf(title: shelf.title, items: shelf.items.map { item in
                    switch item {
                    case .track(let info): .track(track(info))
                    case .place(let info):
                        // A kind this version doesn't know shows as a section.
                        .place(PakPlace(id: info.id, kind: PakPlace.Kind(rawValue: info.kind) ?? .section, title: info.title,
                                        subtitle: info.subtitle, artwork: info.artwork.flatMap(artwork)))
                    }
                })
            },
            cursor: page.cursor)
    }

    /// The cover's id: its URL, or its file as a `file://` URL. Nil if it has neither.
    func artwork(_ info: PakArtworkInfo) -> PakArtwork? {
        if let text = info.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) {
            if let headers = info.headers, !headers.isEmpty { artworkHeaders[url.absoluteString] = headers }
            return PakArtwork(url: url)
        }
        if let path = info.file, !path.isEmpty { return PakArtwork(url: URL(fileURLWithPath: path)) }
        return nil
    }

    func image(for artwork: PakArtwork, size: Int) async -> CGImage? {
        guard let url = URL(string: artwork.id) else { return nil }
        let data: Data
        if url.isFileURL {
            guard let file = try? Data(contentsOf: url) else { return nil }
            data = file
        } else {
            guard ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
            var request = URLRequest(url: url)
            for (field, value) in artworkHeaders[artwork.id] ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
            guard let (body, response) = try? await URLSession.shared.data(for: request) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            data = body
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(size, 1),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Notes

    /// A companion that writes notes, with no music of its own.
    var writesNotes: Bool { manifest.can(PakProtocol.notes) }

    var isMusicSource: Bool { !writesNotes }

    /// How long a notes Pak may go quiet before Bitamp gives up: longer than other requests,
    /// since a lookup on the web can take a while before its first words.
    static let notesTimeout: TimeInterval = 60

    private var lookupKey: String { "pak.\(manifest.id).lookup" }
    private var prefetchKey: String { "pak.\(manifest.id).prefetch" }

    /// "When I ask" until the user picks: Bitamp can't know what a lookup costs, or where it goes.
    var lookup: NotesLookup {
        get { defaults.string(forKey: lookupKey).flatMap(NotesLookup.init) ?? .whenAsked }
        set { defaults.set(newValue.rawValue, forKey: lookupKey) }
    }

    var prefetch: Bool {
        get { defaults.bool(forKey: prefetchKey) }
        set { defaults.set(newValue, forKey: prefetchKey) }
    }

    /// Its notes are saved under its id, apart from Backstory's and other Paks'.
    var identity: String { "pak:\(manifest.id)" }

    /// The Pak itself, unless it needs settings filled in first.
    func choice() -> NotesChoice? {
        guard writesNotes, account != .disconnected else { return nil }
        return NotesChoice(service: PakNotesService(pak: self), identity: identity, onDevice: false)
    }

    func onDeviceChoice() -> NotesChoice? { nil }

    /// Asks the Pak for notes on `track`, handing each piece to `yield` as it comes.
    func writeNotes(_ track: PakNowPlaying, _ yield: @escaping (BackstoryUpdate) -> Void) async throws {
        let song = PakSongInfo(title: track.title, artist: track.artist, album: track.album)
        let decoder = JSONDecoder()
        let result = try await connection.request(PakMethod.notes, PakMethod.Notes(song: song), as: PakMethod.NotesResult.self,
                                                  timeout: Self.notesTimeout) { line in
            guard let update = try? decoder.decode(PakUpdate<PakNotesUpdate>.self, from: line).update else { return }
            Self.updates(text: update.text, cite: update.cite).forEach(yield)
        }
        Self.updates(text: result.text, cite: result.sources).forEach(yield)
    }

    /// What the window adds for a piece of the Pak's notes. Sources that aren't web pages are left out.
    nonisolated static func updates(text: String?, cite: [PakCitation]?) -> [BackstoryUpdate] {
        var updates: [BackstoryUpdate] = []
        if let text, !text.isEmpty { updates.append(.text(text)) }
        let sources = (cite ?? []).compactMap { citation -> BackstorySource? in
            guard let url = URL(string: citation.url), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
            let title = citation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return BackstorySource(title: title.isEmpty ? url.host! : title, url: url, quote: citation.quote)
        }
        if !sources.isEmpty { updates.append(.cite(sources)) }
        return updates
    }
}

/// A notes Pak as the window's service. Stopping the stream, as when the song changes,
/// cancels the request, and Bitamp tells the Pak to stop.
struct PakNotesService: BackstoryService {
    let pak: ExternalPak

    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await pak.writeNotes(track) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
