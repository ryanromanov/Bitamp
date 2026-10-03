import Foundation
import UniformTypeIdentifiers

enum AudioFiles {
    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .playlist)
    }

    /// Keeps audio files, expands folders into the audio files inside them (recursively,
    /// in Finder's name order) and playlists into the files they list. Drops the rest.
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            if M3U.isPlaylist(url) {
                return M3U.read(url).filter { isAudio($0) && FileManager.default.fileExists(atPath: $0.path) }
            }
            guard isDirectory.boolValue else { return isAudio(url) ? [url] : [] }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let files = (enumerator?.allObjects as? [URL] ?? []).filter(isAudio)
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }
}
