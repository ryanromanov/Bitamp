import Foundation

/// Reads and writes `.m3u` / `.m3u8` playlists of local files and Pak tracks.
enum M3U {
    struct Entry {
        var url: URL
        var title: String?
        var duration: Double?
    }

    static func isPlaylist(_ url: URL) -> Bool {
        ["m3u", "m3u8"].contains(url.pathExtension.lowercased())
    }

    /// The file URLs a playlist lists, plus URLs in `schemes`. Relative paths resolve
    /// against the playlist's folder.
    static func read(_ url: URL, schemes: Set<String> = []) -> [URL] {
        readEntries(url, schemes: schemes).map(\.url)
    }

    /// Like `read`, with the title and duration each `#EXTINF` line gives.
    static func readEntries(_ url: URL, schemes: Set<String> = []) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parseEntries(text, relativeTo: url.deletingLastPathComponent(), schemes: schemes)
    }

    static func parse(_ text: String, relativeTo base: URL, schemes: Set<String> = []) -> [URL] {
        parseEntries(text, relativeTo: base, schemes: schemes).map(\.url)
    }

    static func parseEntries(_ text: String, relativeTo base: URL, schemes: Set<String> = []) -> [Entry] {
        var info: (title: String?, duration: Double?)?
        return text.split(whereSeparator: \.isNewline).compactMap { line -> Entry? in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                info = extinf(line.dropFirst("#EXTINF:".count))
                return nil
            }
            guard !line.hasPrefix("#"), let url = url(line, relativeTo: base, schemes: schemes) else { return nil }
            defer { info = nil }
            return Entry(url: url, title: info?.title, duration: info?.duration)
        }
    }

    /// "123,Artist - Title": seconds (-1 for unknown), then the title.
    private static func extinf(_ text: Substring) -> (title: String?, duration: Double?) {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let seconds = Double(parts[0].trimmingCharacters(in: .whitespaces))
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (title.isEmpty ? nil : title, seconds.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// One entry line as a URL, or nil for one Bitamp can't play.
    private static func url(_ entry: String, relativeTo base: URL, schemes: Set<String>) -> URL? {
        guard !entry.isEmpty else { return nil }
        if entry.contains("://") {
            // Web streams aren't supported yet; files and Pak tracks are.
            guard let url = URL(string: entry) else { return nil }
            return url.isFileURL || schemes.contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        // Playlists written on Windows use backslashes.
        let path = (entry.replacingOccurrences(of: "\\", with: "/") as NSString).expandingTildeInPath
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : base.appendingPathComponent(path).standardizedFileURL
    }

    /// Extended M3U with titles and durations, absolute paths, UTF-8.
    static func write(_ entries: [Entry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            let seconds = entry.duration.map { Int($0.rounded()) } ?? -1
            let title = entry.title ?? TrackMetadata.fileName(entry.url)
            lines.append("#EXTINF:\(seconds),\(title)")
            lines.append(entry.url.isFileURL ? entry.url.path : entry.url.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
