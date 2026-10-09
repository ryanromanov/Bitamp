import BitampPakKit
import Foundation
import MusicKit

/// Apple Music through MusicKit: songs from the listener's library, and from the catalog
/// when the app is signed with a team whose App ID has MusicKit turned on.
///
/// MusicKit plays the songs itself, copy-protected, so Bitamp's equalizer and Retro Sound
/// can't reach them; the visualizer listens in through `PakAudioListener` in BitampKit.
/// Playing needs macOS 14 (`ApplicationMusicPlayer`).
@MainActor
public final class AppleMusicPak: Pak {
    public let id = "applemusic"
    public let name = "Apple Music"
    public let schemes: Set<String> = [AppleMusicURL.scheme]
    private var subscription: MusicSubscription?
    /// Created when the first song plays, since `ApplicationMusicPlayer` needs macOS 14.
    private var backend: PlaybackBackend?
    private let songs = SongStore()

    public init() {}

    public var isAvailable: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    public var account: PakAccount {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            if let subscription, !subscription.canPlayCatalogContent {
                return .limited(reason: "No Apple Music subscription; only songs in your library play")
            }
            return .connected(name: nil)
        case .denied, .restricted:
            return .limited(reason: "Bitamp isn't allowed to use Apple Music. Turn it on in System Settings ▸ Privacy & Security ▸ Media & Apple Music")
        default:
            return .disconnected
        }
    }

    public func connect() async throws {
        let status = await MusicAuthorization.request()
        guard status == .authorized else { throw AppleMusicError.notAuthorized }
        subscription = try? await MusicSubscription.current
    }

    public func disconnect() {
        // MusicKit has no sign-out; the permission lives in System Settings. Forget what
        // was cached so the next search asks again.
        subscription = nil
    }

    /// Library songs first, then catalog songs. The catalog is skipped, not an error, when
    /// the library answered and the catalog can't (an unsigned build has no developer token).
    public func search(_ term: String) async throws -> [PakTrack] {
        guard #available(macOS 14, *) else { throw AppleMusicError.needsMacOS14 }
        if MusicAuthorization.currentStatus != .authorized { try await connect() }
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }

        var library: [Song] = []
        var libraryError: Error?
        do {
            var request = MusicLibrarySearchRequest(term: term, types: [Song.self])
            request.limit = 25
            library = Array(try await request.response().songs)
        } catch {
            libraryError = error
        }
        var catalog: [Song] = []
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            catalog = Array(try await request.response().songs)
        } catch {
            NSLog("Bitamp: Apple Music catalog search failed: \(error)")
            if let libraryError { throw libraryError }
        }
        let tracks = library.map { songs.remember($0, from: .library) }
            + catalog.map { songs.remember($0, from: .catalog) }
        return tracks
    }

    public func metadata(for url: URL) async -> PakTrack? {
        guard #available(macOS 14, *), let reference = AppleMusicURL(url),
              MusicAuthorization.currentStatus == .authorized,
              let song = try? await songs.song(for: reference)
        else { return nil }
        return SongStore.track(song, url: url)
    }

    public func playback(for url: URL) throws -> PakPlayback {
        guard #available(macOS 14, *) else { throw AppleMusicError.needsMacOS14 }
        guard AppleMusicURL(url) != nil else { throw AppleMusicError.notASong(url) }
        if backend == nil { backend = AppleMusicBackend(songs: songs) }
        return .backend(backend!)
    }
}

enum AppleMusicError: LocalizedError {
    case notAuthorized
    case needsMacOS14
    case notASong(URL)
    case notFound(URL)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Bitamp isn't allowed to use Apple Music."
        case .needsMacOS14: return "Apple Music in Bitamp needs macOS 14 or later."
        case .notASong(let url): return "\(url) isn't an Apple Music song."
        case .notFound(let url): return "\(url) isn't in Apple Music any more."
        }
    }
}

/// Songs already looked up, by queue URL, so playing one that came from a search
/// doesn't ask MusicKit again.
@MainActor
final class SongStore {
    private var songs: [AppleMusicURL: Song] = [:]

    func remember(_ song: Song, from source: AppleMusicURL.Source) -> PakTrack {
        let reference = AppleMusicURL(source: source, id: song.id.rawValue)
        songs[reference] = song
        return Self.track(song, url: reference.url)
    }

    func cached(_ reference: AppleMusicURL) -> Song? {
        songs[reference]
    }

    @available(macOS 14, *)
    func song(for reference: AppleMusicURL) async throws -> Song {
        if let song = songs[reference] { return song }
        let found: Song?
        switch reference.source {
        case .library:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(reference.id))
            found = try await request.response().items.first
        case .catalog:
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(reference.id))
            found = try await request.response().items.first
        }
        guard let found else { throw AppleMusicError.notFound(reference.url) }
        songs[reference] = found
        return found
    }

    static func track(_ song: Song, url: URL) -> PakTrack {
        PakTrack(url: url, title: song.title, artist: song.artistName, album: song.albumTitle, duration: duration(of: song))
    }

    /// The song's length in seconds. On macOS 27.2, library songs give `duration` in
    /// milliseconds (180793 for a 3:00 song), so anything over a day is taken as that.
    static func duration(of song: Song) -> Double? {
        guard let duration = song.duration, duration > 0 else { return nil }
        return duration > 86_400 ? duration / 1000 : duration
    }
}
