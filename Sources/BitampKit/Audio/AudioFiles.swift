import Foundation
import UniformTypeIdentifiers

enum AudioFiles {
    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .playlist)
    }

    /// Keeps audio files, expands folders into the audio files inside them (recursively,
    /// in Finder's name order) and playlists into the files they list. Drops the rest,
    /// except URLs in `schemes`: Pak tracks, kept as they are.
    static func expand(_ urls: [URL], schemes: Set<String> = []) -> [URL] {
        expandEntries(urls, schemes: schemes).map(\.url)
    }

    /// Like `expand`, keeping the titles and durations playlists give.
    static func expandEntries(_ urls: [URL], schemes: Set<String> = []) -> [M3U.Entry] {
        urls.flatMap { url -> [M3U.Entry] in
            if let scheme = url.scheme?.lowercased(), schemes.contains(scheme) { return [M3U.Entry(url: url)] }
            // An Expansion Pak is a folder, but not one of music.
            if PakLibrary.isPak(url) { return [] }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            if M3U.isPlaylist(url) {
                return M3U.readEntries(url, schemes: schemes).filter {
                    !$0.url.isFileURL || isAudio($0.url) && FileManager.default.fileExists(atPath: $0.url.path)
                }
            }
            guard isDirectory.boolValue else { return isAudio(url) ? [M3U.Entry(url: url)] : [] }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let files = (enumerator?.allObjects as? [URL] ?? []).filter(isAudio)
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { M3U.Entry(url: $0) }
        }
    }
}
