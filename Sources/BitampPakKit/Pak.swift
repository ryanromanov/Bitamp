import CoreGraphics
import Foundation

/// An Expansion Pak: a music source beyond local files, such as a streaming service or a
/// Navidrome server. Its tracks sit in the queue as URLs in its own scheme
/// (`bitpak-demo://track/ode-to-joy`).
@MainActor
public protocol Pak: AnyObject {
    /// Stable and unique, used for preferences ("demo").
    var id: String { get }
    /// "Demo"; the UI adds "Pak".
    var name: String { get }
    /// URL schemes this Pak's tracks use.
    var schemes: Set<String> { get }
    /// False when this Mac can't run it (too old a macOS, say). Unavailable Paks show
    /// greyed out and are never asked to play.
    var isAvailable: Bool { get }
    var account: PakAccount { get }

    /// Signs in or asks for permission, showing whatever UI the service needs.
    func connect() async throws
    func disconnect()

    func search(_ term: String) async throws -> [PakTrack]
    /// What's known about one of this Pak's tracks, for the playlist.
    func metadata(for url: URL) async -> PakTrack?
    /// How to play one of this Pak's tracks.
    func playback(for url: URL) throws -> PakPlayback

    // Browsing, for the Media Library. Paks that only search can leave these out.

    /// Whether `browse` offers more than search: a sidebar from `.root`, and places.
    var canBrowse: Bool { get }
    /// What's at `location`, or more of it after the `cursor` an earlier page gave.
    func browse(_ location: PakLocation, after cursor: String?) async throws -> PakPage
    /// The picture for `artwork`, about `size` pixels square, or nil if there's none.
    func image(for artwork: PakArtwork, size: Int) async -> CGImage?

    /// False for a companion Pak, such as Backstory, which adds to what's playing instead
    /// of supplying music: it has no tracks, and isn't offered for browsing.
    var isMusicSource: Bool { get }
}

extension Pak {
    public var canBrowse: Bool { false }
    public var isMusicSource: Bool { true }

    /// Search's tracks for `.search`, and nothing anywhere else.
    public func browse(_ location: PakLocation, after cursor: String?) async throws -> PakPage {
        switch location {
        case .search(let term):
            guard cursor == nil else { return PakPage() }
            return PakPage(shelves: [PakShelf(items: try await search(term).map(PakItem.track))])
        case .root:
            return PakPage()
        case .place(let id):
            throw PakBrowseError.notFound(id)
        }
    }

    /// Fetches art with a web address.
    public func image(for artwork: PakArtwork, size: Int) async -> CGImage? {
        await artwork.download()
    }
}

public enum PakAccount: Sendable, Equatable {
    case disconnected
    case connected(name: String?)
    /// Connected, but this account can't play (no subscription, say).
    case limited(reason: String)
}

public enum PakPlayback {
    /// A local file Bitamp's engine plays, with the equalizer, visualizer and Retro Sound.
    case stream(URL)
    /// Like `stream`, for a file that takes a while to get ready (asked of another program,
    /// downloaded). Bitamp shows the track as loading until it arrives.
    case fetch(@MainActor () async throws -> URL)
    /// A backend that plays the track itself. Bitamp reuses it for later tracks.
    case backend(PlaybackBackend)
}

public struct PakTrack: Sendable, Equatable {
    public let url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: Double?
    /// The track's album art, for the Media Library and what's playing.
    public var artwork: PakArtwork?

    public init(url: URL, title: String, artist: String? = nil, album: String? = nil, duration: Double? = nil,
                artwork: PakArtwork? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
    }
}
