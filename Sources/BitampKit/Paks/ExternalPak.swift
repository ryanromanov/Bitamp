import BitampPakProtocol
import CryptoKit
import Foundation

/// A third-party Pak: a `.bitpak` folder whose program Bitamp runs and talks to (see
/// `PakConnection`). Its tracks are `bitpak-<id>://track/<the Pak's id>`; they play through
/// Bitamp's engine, so the equalizer, visualizer and Retro Sound all work.
@MainActor
final class ExternalPak: Pak {
    let manifest: PakManifest
    /// The installed `.bitpak` folder.
    let folder: URL
    private let settings: PakSettingsStore
    private lazy var connection = PakConnection(
        executable: folder.appendingPathComponent(manifest.executable), name: manifest.name,
        hello: { [unowned self] in
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return (PakMethod.hello, PakMethod.Hello(
                protocol: PakProtocol.version, settings: settings.values(for: manifest),
                cacheDirectory: cacheDirectory.path))
        })
    private var lastAccount: PakAccountState?

    init(manifest: PakManifest, folder: URL, settings: PakSettingsStore) {
        self.manifest = manifest
        self.folder = folder
        self.settings = settings
        connection.onHello = { [weak self] result in self?.lastAccount = result.account }
    }

    var id: String { manifest.id }
    var name: String { manifest.name }
    var schemes: Set<String> { [Self.scheme(for: manifest.id)] }
    var hasSettings: Bool { !(manifest.settings ?? []).isEmpty }

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
        PakTrack(url: trackURL(info.id), title: info.title, artist: info.artist, album: info.album, duration: info.duration)
    }
}
