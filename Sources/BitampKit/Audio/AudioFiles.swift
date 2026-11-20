import Foundation
import UniformTypeIdentifiers

enum AudioFiles {
    /// Whether each file extension seen is audio. Asking the system for a type is slow
    /// enough to matter across a library of tens of thousands of files.
    private static let extensionCache = NSLock()
    nonisolated(unsafe) private static var audioExtensions: [String: Bool] = [:]

    static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        extensionCache.lock()
        defer { extensionCache.unlock() }
        if let known = audioExtensions[ext] { return known }
        let audio = UTType(filenameExtension: ext).map { $0.conforms(to: .audio) && !$0.conforms(to: .playlist) } ?? false
        audioExtensions[ext] = audio
        return audio
    }

    /// Whether reading `urls` means walking folders or reading playlists, which can take a
    /// while on a big library or a network volume, so it's done off the main thread.
    static func needsReading(_ urls: [URL], schemes: Set<String> = []) -> Bool {
        urls.contains { url in
            if let scheme = url.scheme?.lowercased(), schemes.contains(scheme) { return false }
            if M3U.isPlaylist(url) { return true }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
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
