import BitampPakKit
import Foundation
import MusicKit

/// The Apple Music Pak's side of the Media Library: the sidebar, its sections, and album,
/// artist and playlist pages, from the listener's library and, with a subscription, the
/// catalog.
///
/// Places are `section/<name>` or `<source>-<kind>/<MusicKit id>`, such as
/// `library-album/123`. Items listed are kept, so opening one doesn't ask MusicKit for it
/// again; one that isn't kept (from an earlier launch) is looked up by its id.
@available(macOS 14, *)
@MainActor
final class AppleMusicBrowser {
    private let songs: SongStore
    private var art: ArtworkStore { songs.art }
    private var albums: [String: Album] = [:]
    private var artists: [String: Artist] = [:]
    private var playlists: [String: Playlist] = [:]
    /// A section's songs, albums, artists or playlists come this many at a time.
    static let pageSize = 100

    init(songs: SongStore) {
        self.songs = songs
    }

    enum Section: String, CaseIterable {
        case recentlyAdded = "recently-added", albums, artists, songs, playlists
        case forYou = "for-you", recentlyPlayed = "recently-played", charts

        var title: String {
            switch self {
            case .recentlyAdded: return "Recently Added"
            case .albums: return "Albums"
            case .artists: return "Artists"
            case .songs: return "Songs"
            case .playlists: return "Playlists"
            case .forYou: return "For You"
            case .recentlyPlayed: return "Recently Played"
            case .charts: return "Top Charts"
            }
        }

        var needsCatalog: Bool {
            [.forYou, .recentlyPlayed, .charts].contains(self)
        }

        var place: PakPlace {
            PakPlace(id: "section/" + rawValue, kind: .section, title: title)
        }
    }

    /// The library's sections, and the catalog's when the listener can play from it.
    func root(catalog: Bool) -> PakPage {
        var shelves = [PakShelf(title: "Library", items: Section.allCases.filter { !$0.needsCatalog }.map { .place($0.place) })]
        if catalog {
            shelves.append(PakShelf(title: "Apple Music", items: Section.allCases.filter(\.needsCatalog).map { .place($0.place) }))
        }
        return PakPage(shelves: shelves)
    }

    func page(_ id: String, after cursor: String?) async throws -> PakPage {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw PakBrowseError.notFound(id) }
        let (kind, itemID) = (parts[0], parts[1])
        if kind == "section" {
            guard let section = Section(rawValue: itemID) else { throw PakBrowseError.notFound(id) }
            return try await page(section, offset: cursor.flatMap(Int.init) ?? 0)
        }
        // Albums, artists and playlists fit on one page.
        guard cursor == nil else { return PakPage() }
        switch kind {
        case "library-album", "catalog-album": return try await albumPage(id, itemID, library: kind.hasPrefix("library"))
        case "library-artist", "catalog-artist": return try await artistPage(id, itemID, library: kind.hasPrefix("library"))
        case "library-playlist", "catalog-playlist": return try await playlistPage(id, itemID, library: kind.hasPrefix("library"))
        default: throw PakBrowseError.notFound(id)
        }
    }

    // MARK: - Sections

    private func page(_ section: Section, offset: Int) async throws -> PakPage {
        switch section {
        case .recentlyAdded:
            guard offset == 0 else { return PakPage() }
            var request = MusicLibraryRequest<Album>()
            request.sort(by: \.libraryAddedDate, ascending: false)
            request.limit = 60
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.compactMap { place($0, library: true) })])
        case .albums:
            var request = MusicLibraryRequest<Album>()
            request.sort(by: \.title, ascending: true)
            request.limit = Self.pageSize
            request.offset = offset
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.compactMap { place($0, library: true) })],
                           cursor: next(offset, found.count))
        case .artists:
            var request = MusicLibraryRequest<Artist>()
            request.sort(by: \.name, ascending: true)
            request.limit = Self.pageSize
            request.offset = offset
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.compactMap { place($0, library: true) })],
                           cursor: next(offset, found.count))
        case .songs:
            var request = MusicLibraryRequest<Song>()
            request.sort(by: \.title, ascending: true)
            request.limit = Self.pageSize
            request.offset = offset
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.map { .track(songs.remember($0, from: .library)) })],
                           cursor: next(offset, found.count))
        case .playlists:
            var request = MusicLibraryRequest<Playlist>()
            request.sort(by: \.name, ascending: true)
            request.limit = Self.pageSize
            request.offset = offset
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.compactMap { place($0, library: true) })],
                           cursor: next(offset, found.count))
        case .forYou:
            guard offset == 0 else { return PakPage() }
            let found = try await MusicPersonalRecommendationsRequest().response().recommendations
            return PakPage(shelves: found.compactMap { recommendation in
                let items = recommendation.items.compactMap { item -> PakItem? in
                    switch item {
                    case .album(let album): return place(album, library: false)
                    case .playlist(let playlist): return place(playlist, library: false)
                    default: return nil // Stations don't fit a playlist.
                    }
                }
                return items.isEmpty ? nil : PakShelf(title: recommendation.title, items: items)
            })
        case .recentlyPlayed:
            guard offset == 0 else { return PakPage() }
            var request = MusicRecentlyPlayedContainerRequest()
            request.limit = 30
            let found = try await request.response().items
            return PakPage(shelves: [PakShelf(items: found.compactMap { item -> PakItem? in
                switch item {
                case .album(let album): return place(album, library: false)
                case .playlist(let playlist): return place(playlist, library: false)
                default: return nil
                }
            })])
        case .charts:
            guard offset == 0 else { return PakPage() }
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self, Album.self, Playlist.self])
            request.limit = 25
            let charts = try await request.response()
            var shelves: [PakShelf] = []
            for chart in charts.songCharts {
                shelves.append(PakShelf(title: chart.title, items: chart.items.map { .track(songs.remember($0, from: .catalog)) }))
            }
            for chart in charts.albumCharts {
                shelves.append(PakShelf(title: chart.title, items: chart.items.compactMap { place($0, library: false) }))
            }
            for chart in charts.playlistCharts {
                shelves.append(PakShelf(title: chart.title, items: chart.items.compactMap { place($0, library: false) }))
            }
            return PakPage(shelves: shelves.filter { !$0.items.isEmpty })
        }
    }

    /// The cursor for the next page, when this one was full.
    private func next(_ offset: Int, _ count: Int) -> String? {
        count < Self.pageSize ? nil : String(offset + count)
    }

    // MARK: - Search

    /// Songs, albums, artists and playlists, from the library and then the catalog. The
    /// catalog is left out, not an error, when the library answered and it can't.
    func search(_ term: String) async throws -> PakPage {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return PakPage() }
        var library: MusicLibrarySearchResponse?
        var libraryError: Error?
        do {
            var request = MusicLibrarySearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
            request.limit = 25
            library = try await request.response()
        } catch {
            libraryError = error
        }
        var catalog: MusicCatalogSearchResponse?
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
            request.limit = 25
            catalog = try await request.response()
        } catch {
            NSLog("Bitamp: Apple Music catalog search failed: \(error)")
            if let libraryError { throw libraryError }
        }
        var shelves: [PakShelf] = []
        func add(_ title: String, _ items: [PakItem]) {
            if !items.isEmpty { shelves.append(PakShelf(title: title, items: items)) }
        }
        add("Songs", (library?.songs.map { .track(songs.remember($0, from: .library)) } ?? [])
            + (catalog?.songs.map { .track(songs.remember($0, from: .catalog)) } ?? []))
        add("Albums", (library?.albums.compactMap { place($0, library: true) } ?? [])
            + (catalog?.albums.compactMap { place($0, library: false) } ?? []))
        add("Artists", (library?.artists.compactMap { place($0, library: true) } ?? [])
            + (catalog?.artists.compactMap { place($0, library: false) } ?? []))
        add("Playlists", (library?.playlists.compactMap { place($0, library: true) } ?? [])
            + (catalog?.playlists.compactMap { place($0, library: false) } ?? []))
        return PakPage(shelves: shelves)
    }

    // MARK: - Places

    /// An album to list, or nil for one with no title: the library has some of those,
    /// with wide art, that look like music videos.
    private func place(_ album: Album, library: Bool) -> PakItem? {
        guard !album.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let id = (library ? "library-album/" : "catalog-album/") + album.id.rawValue
        albums[id] = album
        return .place(PakPlace(id: id, kind: .album, title: album.title, subtitle: album.artistName,
                               artwork: art.reference(album.artwork)))
    }

    private func place(_ artist: Artist, library: Bool) -> PakItem? {
        guard !artist.name.isEmpty else { return nil }
        let id = (library ? "library-artist/" : "catalog-artist/") + artist.id.rawValue
        artists[id] = artist
        return .place(PakPlace(id: id, kind: .artist, title: artist.name, artwork: art.reference(artist.artwork)))
    }

    private func place(_ playlist: Playlist, library: Bool) -> PakItem? {
        let id = (library ? "library-playlist/" : "catalog-playlist/") + playlist.id.rawValue
        playlists[id] = playlist
        return .place(PakPlace(id: id, kind: .playlist, title: playlist.name, subtitle: playlist.curatorName,
                               artwork: art.reference(playlist.artwork)))
    }

    private func albumPage(_ id: String, _ itemID: String, library: Bool) async throws -> PakPage {
        var album = albums[id]
        if album == nil {
            if library {
                var request = MusicLibraryRequest<Album>()
                request.filter(matching: \.id, equalTo: MusicItemID(itemID))
                album = try await request.response().items.first
            } else {
                album = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(itemID))
                    .response().items.first
            }
        }
        guard let found = try await album?.with([.tracks]) else { throw PakBrowseError.notFound(id) }
        let tracks = (found.tracks ?? []).compactMap { track -> PakItem? in
            guard case .song(let song) = track else { return nil }
            return .track(songs.remember(song, from: library ? .library : .catalog))
        }
        let year = found.releaseDate.map { String(Calendar.current.component(.year, from: $0)) }
        let detail = ([found.genreNames.first, year].compactMap { $0 } + [songCount(tracks.count)]).joined(separator: " · ")
        return PakPage(
            header: PakHeader(title: found.title, subtitle: found.artistName, detail: detail, artwork: art.reference(found.artwork)),
            shelves: [PakShelf(items: tracks)])
    }

    /// A library artist's albums in the library; a catalog artist's top songs and albums.
    private func artistPage(_ id: String, _ itemID: String, library: Bool) async throws -> PakPage {
        if library {
            var name = artists[id]?.name
            if name == nil {
                var request = MusicLibraryRequest<Artist>()
                request.filter(matching: \.id, equalTo: MusicItemID(itemID))
                name = try await request.response().items.first?.name
            }
            guard let name else { throw PakBrowseError.notFound(id) }
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.artistName, equalTo: name)
            request.sort(by: \.title, ascending: true)
            let found = try await request.response().items
            return PakPage(header: PakHeader(title: name, artwork: art.reference(artists[id]?.artwork)),
                           shelves: [PakShelf(title: "Albums", items: found.compactMap { place($0, library: true) })])
        }
        var artist = artists[id]
        if artist == nil {
            artist = try await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(itemID))
                .response().items.first
        }
        guard let found = try await artist?.with([.topSongs, .albums]) else { throw PakBrowseError.notFound(id) }
        var shelves: [PakShelf] = []
        let top = (found.topSongs ?? []).map { PakItem.track(songs.remember($0, from: .catalog)) }
        if !top.isEmpty { shelves.append(PakShelf(title: "Top Songs", items: top)) }
        let albums = (found.albums ?? []).compactMap { place($0, library: false) }
        if !albums.isEmpty { shelves.append(PakShelf(title: "Albums", items: albums)) }
        return PakPage(header: PakHeader(title: found.name, artwork: art.reference(found.artwork)), shelves: shelves)
    }

    private func playlistPage(_ id: String, _ itemID: String, library: Bool) async throws -> PakPage {
        var playlist = playlists[id]
        if playlist == nil {
            if library {
                var request = MusicLibraryRequest<Playlist>()
                request.filter(matching: \.id, equalTo: MusicItemID(itemID))
                playlist = try await request.response().items.first
            } else {
                playlist = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(itemID))
                    .response().items.first
            }
        }
        guard let found = try await playlist?.with([.tracks]) else { throw PakBrowseError.notFound(id) }
        let tracks = (found.tracks ?? []).compactMap { track -> PakItem? in
            guard case .song(let song) = track else { return nil }
            return .track(songs.remember(song, from: library ? .library : .catalog))
        }
        return PakPage(
            header: PakHeader(title: found.name, subtitle: found.curatorName, detail: songCount(tracks.count),
                              artwork: art.reference(found.artwork)),
            shelves: [PakShelf(items: tracks)])
    }

    private func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }
}
