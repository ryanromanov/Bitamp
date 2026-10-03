import Foundation

/// Reads and writes `.m3u` / `.m3u8` playlists of local files.
enum M3U {
    struct Entry {
        var url: URL
        var title: String?
        var duration: Double?
    }

    static func isPlaylist(_ url: URL) -> Bool {
        ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    /// The file URLs a playlist lists. Relative paths resolve against the playlist's folder.
    static func read(_ url: URL) -> [URL] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text, relativeTo: url.deletingLastPathComponent())
    }

    static func parse(_ text: String, relativeTo base: URL) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { return nil }
            if entry.contains("://") {
                // Streams aren't supported yet; file URLs are.
                guard let url = URL(string: entry), url.isFileURL else { return nil }
                return url
            }
            // Playlists written on Windows use backslashes.
            let path = (entry.replacingOccurrences(of: "\\", with: "/") as NSString).expandingTildeInPath
            return path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : base.appendingPathComponent(path).standardizedFileURL
        }
    }

    /// Extended M3U with titles and durations, absolute paths, UTF-8.
    static func write(_ entries: [Entry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            let seconds = entry.duration.map { Int($0.rounded()) } ?? -1
            let title = entry.title ?? TrackMetadata.fileName(entry.url)
            lines.append("#EXTINF:\(seconds),\(title)")
            lines.append(entry.url.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
