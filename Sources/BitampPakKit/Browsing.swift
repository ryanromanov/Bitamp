import CoreGraphics
import Foundation
import ImageIO

/// Somewhere to look in a Pak's music, for the Media Library.
public enum PakLocation: Hashable, Sendable {
    /// The sidebar: a shelf per group ("Library", "Apple Music"), each item a section.
    /// Asked for each time the Media Library opens, since playlists come and go.
    case root
    /// A place the Pak listed: a section, an album, an artist, a playlist.
    case place(String)
    case search(String)
}

/// What's at a location: an optional header, for an album or playlist of its own, and
/// shelves of tracks and places. One shelf without a title is a plain list.
public struct PakPage: Sendable, Equatable {
    public var header: PakHeader?
    public var shelves: [PakShelf]
    /// More of the last shelf. Passing it back to `browse` gives a page whose shelves
    /// carry on from this one's last.
    public var cursor: String?

    public init(header: PakHeader? = nil, shelves: [PakShelf] = [], cursor: String? = nil) {
        self.header = header
        self.shelves = shelves
        self.cursor = cursor
    }

    /// Every track on the page, in order.
    public var tracks: [PakTrack] {
        shelves.flatMap { $0.items.compactMap(\.track) }
    }
}

/// The top of an album or playlist page.
public struct PakHeader: Sendable, Equatable {
    public var title: String
    /// The artist, or who made the playlist.
    public var subtitle: String?
    /// "Electronic · 2025 · 10 songs".
    public var detail: String?
    public var artwork: PakArtwork?

    public init(title: String, subtitle: String? = nil, detail: String? = nil, artwork: PakArtwork? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.artwork = artwork
    }
}

/// A row of a page: "Albums", "Top Songs", "Made for You".
public struct PakShelf: Sendable, Equatable {
    public var title: String?
    public var items: [PakItem]

    public init(title: String? = nil, items: [PakItem]) {
        self.title = title
        self.items = items
    }
}

public enum PakItem: Sendable, Equatable {
    case track(PakTrack)
    case place(PakPlace)

    public var track: PakTrack? {
        if case .track(let track) = self { return track }
        return nil
    }

    public var place: PakPlace? {
        if case .place(let place) = self { return place }
        return nil
    }
}

/// Something to open: a section of the sidebar, or an album, artist or playlist.
public struct PakPlace: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case section, album, artist, playlist
    }

    /// The Pak's own, passed back as `.place(id)`. Bitamp never looks inside it.
    public let id: String
    public var kind: Kind
    public var title: String
    /// An album's artist, a playlist's curator.
    public var subtitle: String?
    public var artwork: PakArtwork?

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, artwork: PakArtwork? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
    }
}

/// A picture a Pak can draw, by a name of its own: often an http(s) URL, which Bitamp can
/// fetch by itself, or a key for art only the Pak can reach.
public struct PakArtwork: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(url: URL) {
        id = url.absoluteString
    }

    /// The art's http(s) address, when it has one.
    public var webURL: URL? {
        guard let url = URL(string: id), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// Downloads and decodes art that has a web address.
    public func download() async -> CGImage? {
        guard let webURL, let (data, response) = try? await URLSession.shared.data(from: webURL) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

public enum PakBrowseError: LocalizedError, Equatable {
    /// Asked for a place it never listed, or one that's gone.
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "That isn't there any more."
        }
    }
}

extension Pak {
    /// Every track at `location`, following the pages' cursors, for playing or adding a
    /// whole album or playlist. Stops at `limit` tracks, at a page with no tracks, and at
    /// a cursor it has seen before.
    public func allTracks(at location: PakLocation, limit: Int = 1_000) async throws -> [PakTrack] {
        var tracks: [PakTrack] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await browse(location, after: cursor)
            let found = page.tracks
            tracks += found
            cursor = page.cursor
            if found.isEmpty { break }
            if let next = cursor, !seen.insert(next).inserted { break }
        } while cursor != nil && tracks.count < limit
        return Array(tracks.prefix(limit))
    }
}
