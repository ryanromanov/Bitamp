import AVFoundation

/// What a file's tags and headers say about it. Any field can be missing.
struct TrackMetadata: Sendable, Equatable {
    var title: String?
    var artist: String?
    var duration: Double?
    var kbps: Int?

    static func load(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = TrackMetadata()
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            switch item.commonKey {
            case .commonKeyTitle?: metadata.title = try? await item.load(.stringValue)
            case .commonKeyArtist?: metadata.artist = try? await item.load(.stringValue)
            default: break
            }
        }
        if metadata.title?.isEmpty == true { metadata.title = nil }
        if metadata.artist?.isEmpty == true { metadata.artist = nil }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            metadata.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            metadata.kbps = Int((rate / 1000).rounded())
        }
        return metadata
    }

    /// "Artist - Title", the title alone, or the file name without its extension.
    func displayName(for url: URL) -> String {
        guard let title else { return Self.fileName(url) }
        guard let artist else { return title }
        return "\(artist) - \(title)"
    }

    static func fileName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Metadata for the playlist, loaded in the background a few files at a time.
@MainActor
final class TrackInfoStore {
    static let maxConcurrentLoads = 4

    private var cache: [URL: TrackMetadata] = [:]
    private var waiting: [URL] = []
    private var requested: Set<URL> = []
    private var loading = 0

    /// The cached metadata, or nil while it loads. Asking starts the load.
    func metadata(for url: URL) -> TrackMetadata? {
        if let metadata = cache[url] { return metadata }
        request(url)
        return nil
    }

    func displayName(for url: URL) -> String {
        metadata(for: url)?.displayName(for: url) ?? TrackMetadata.fileName(url)
    }

    func duration(for url: URL) -> Double? {
        metadata(for: url)?.duration
    }

    private func request(_ url: URL) {
        guard !requested.contains(url) else { return }
        requested.insert(url)
        waiting.append(url)
        startLoads()
    }

    private func startLoads() {
        while loading < Self.maxConcurrentLoads, !waiting.isEmpty {
            let url = waiting.removeFirst()
            loading += 1
            Task {
                let metadata = await TrackMetadata.load(from: url)
                self.cache[url] = metadata
                self.loading -= 1
                self.startLoads()
            }
        }
    }
}
