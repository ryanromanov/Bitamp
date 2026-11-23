import Foundation

/// A song as a queue URL: `applemusic://library/song/<id>` for one in the listener's
/// library, `applemusic://catalog/song/<id>` for one in the Apple Music catalog. The two
/// kinds of ID can't be swapped, so the URL says which it is.
struct AppleMusicURL: Hashable, Sendable {
    enum Source: String, Sendable {
        case library, catalog
    }

    static let scheme = "applemusic"

    let source: Source
    let id: String

    init(source: Source, id: String) {
        self.source = source
        self.id = id
    }

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host, let source = Source(rawValue: host.lowercased())
        else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "song", let id = parts[1].removingPercentEncoding, !id.isEmpty else { return nil }
        self.init(source: source, id: id)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = source.rawValue
        components.path = "/song/\(id)"
        return components.url!
    }
}
