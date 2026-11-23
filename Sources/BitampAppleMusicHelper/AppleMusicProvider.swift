import AppKit
import BitampPakKit
import BitampPakSDK
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Apple Music as a Pak of its own program: the built-in `AppleMusicPak`, answering over the
/// Pak protocol instead of in Bitamp's process. It plays through MusicKit itself, so the
/// program has to be an app with MusicKit's entitlement (scripts/make-applemusic-pak.sh).
///
/// Track ids are the built-in Pak's URLs without the scheme (`library/song/123`,
/// `catalog/song/123`), so an `applemusic://` URL turns into one by dropping the scheme, and
/// back by adding it.
@MainActor
final class AppleMusicProvider: PakProvider {
    private let pak: AppleMusicPak
    private var cacheDirectory = FileManager.default.temporaryDirectory
    /// False until Bitamp's first call, which only reports what's already allowed; later calls
    /// are the listener choosing to connect, and may ask for permission.
    private var started = false
    private let player: Player

    init(pak: AppleMusicPak) {
        self.pak = pak
        player = Player(pak: pak)
    }

    nonisolated func attach(_ reporter: PakPlaybackReporter) {
        player.reporter.set(reporter)
    }

    // MARK: - Account

    func configure(_ context: PakContext) async throws -> PakAccountState {
        cacheDirectory = context.cacheDirectory
        if started { try await pak.connect() }
        started = true
        return Self.account(pak.account)
    }

    nonisolated static func account(_ account: PakAccount) -> PakAccountState {
        switch account {
        case .disconnected: return PakAccountState(.disconnected)
        case .connected(let name): return PakAccountState(.connected, message: name)
        case .limited(let reason): return PakAccountState(.limited, message: reason)
        }
    }

    // MARK: - Music

    func search(_ term: String) async throws -> [PakTrackInfo] {
        try await pak.search(term).map(Self.track)
    }

    func track(id: String) async throws -> PakTrackInfo? {
        guard let url = Self.url(id) else { return nil }
        return await pak.metadata(for: url).map(Self.track)
    }

    func browse(_ location: PakBrowseLocation, cursor: String?) async throws -> PakBrowsePage {
        let there: PakLocation = switch location {
        case .root: .root
        case .place(let id): .place(id)
        case .search(let term): .search(term)
        }
        return Self.page(try await pak.browse(there, after: cursor))
    }

    // MARK: - Mapping

    /// `applemusic://library/song/123` → `library/song/123`.
    nonisolated static func id(_ url: URL) -> String {
        let prefix = "applemusic://"
        let text = url.absoluteString
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    nonisolated static func url(_ id: String) -> URL? {
        URL(string: "applemusic://" + id)
    }

    nonisolated static func track(_ track: PakTrack) -> PakTrackInfo {
        PakTrackInfo(id: id(track.url), title: track.title, artist: track.artist, album: track.album,
                     duration: track.duration, artwork: track.artwork.map(art))
    }

    /// The built-in Pak's art keys name what the art belongs to (not an address), which is
    /// what an artwork `id` is for: Bitamp asks for the picture when it wants it.
    nonisolated static func art(_ artwork: PakArtwork) -> PakArtworkInfo {
        PakArtworkInfo(id: artwork.id)
    }

    nonisolated static func page(_ page: PakPage) -> PakBrowsePage {
        PakBrowsePage(
            header: page.header.map { PakHeaderInfo(title: $0.title, subtitle: $0.subtitle, detail: $0.detail, artwork: $0.artwork.map(art)) },
            shelves: page.shelves.map { shelf in
                PakShelfInfo(title: shelf.title, items: shelf.items.map { item in
                    switch item {
                    case .track(let track): .track(Self.track(track))
                    case .place(let place):
                        .place(PakPlaceInfo(kind: place.kind.rawValue, id: place.id, title: place.title, subtitle: place.subtitle,
                                            artwork: place.artwork.map(art)))
                    }
                })
            },
            cursor: page.cursor)
    }

    // MARK: - Artwork

    func artwork(id: String, size: Int) async throws -> URL? {
        guard let image = await pak.image(for: PakArtwork(id), size: size), !Task.isCancelled else { return nil }
        let folder = cacheDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent("\(digest.prefix(32))-\(size).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return file
    }

    // MARK: - Playback

    func load(id: String) async throws -> PakPlaybackLoad {
        guard let url = Self.url(id) else { throw PakFailure("\(id) isn't an Apple Music song.") }
        let info = try player.load(url)
        // The song may be in Bitamp's list from an earlier launch, and unknown until it's looked up.
        let found = await pak.metadata(for: url)
        return PakPlaybackLoad(duration: found?.duration ?? info?.duration, title: found?.title ?? info?.title,
                               artist: found?.artist ?? info?.artist, audio: PakAudioProcess.appleMusic)
    }

    func play() async throws { player.play() }
    func pause() async throws { player.pause() }
    func resume() async throws { player.resume() }
    func stop() async throws { player.stop() }
    func seek(to seconds: Double) async throws { player.seek(to: seconds) }
}

/// Holds the reporter, which arrives on another thread than the one the Pak's work is on.
final class ReporterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reporter: PakPlaybackReporter?

    func set(_ reporter: PakPlaybackReporter) {
        lock.lock()
        self.reporter = reporter
        lock.unlock()
    }

    var current: PakPlaybackReporter? {
        lock.lock()
        defer { lock.unlock() }
        return reporter
    }
}

/// The built-in Pak's player, with what it does reported to Bitamp: its state and place every
/// half second while it plays, and at once when either changes; the song ending; a song that
/// won't play, with the built-in player's advice.
@MainActor
final class Player {
    nonisolated let reporter = ReporterBox()
    private let pak: AppleMusicPak
    private var backend: PlaybackBackend?
    private var ticker: Timer?
    private var lastState: PlaybackState?

    init(pak: AppleMusicPak) {
        self.pak = pak
    }

    /// Loads `url` into the player, stopped. Returns what the player already knows of the song.
    func load(_ url: URL) throws -> NowPlaying? {
        guard case .backend(let backend) = try pak.playback(for: url) else { throw PakFailure("This song can't be played here.") }
        if self.backend !== backend { follow(backend) }
        try backend.load(url)
        lastState = backend.state
        startTicking()
        return backend.nowPlaying
    }

    func play() {
        backend?.play()
        report()
    }

    func pause() {
        if backend?.state == .playing { backend?.pause() }
        report()
    }

    func resume() {
        backend?.play()
        report()
    }

    func stop() {
        backend?.stop()
        report()
    }

    func seek(to seconds: Double) {
        backend?.seek(to: seconds)
        report()
    }

    private func follow(_ backend: PlaybackBackend) {
        self.backend = backend
        backend.onTrackEnd = { [weak self] in
            self?.lastState = .stopped
            self?.reporter.current?.ended()
        }
        backend.onLoadFailure = { [weak self] error in
            self?.lastState = .stopped
            let advice = error as? PlaybackAdvice
            self?.reporter.current?.failed(advice?.title ?? error.localizedDescription, advice: advice?.advice)
        }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let backend else { return }
        // While playing, every tick; otherwise only a change, such as a pause from the media keys.
        if backend.state == .playing || backend.state != lastState { report() }
    }

    private func report() {
        guard let backend else { return }
        lastState = backend.state
        let state: PakPlayerState = switch backend.state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
        let duration = backend.nowPlaying?.duration
        reporter.current?.report(state, position: backend.currentTime, duration: duration.flatMap { $0 > 0 ? $0 : nil })
    }
}
