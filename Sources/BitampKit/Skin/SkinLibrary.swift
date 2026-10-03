import Foundation

/// Installed `.wsz` skins live in Application Support, so they keep working if the
/// original download is moved or deleted.
enum SkinLibrary {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bitamp/Skins", isDirectory: true)
    }

    static func isSkin(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "wsz"
    }

    /// Installed skins in Finder name order.
    static func installed() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter(isSkin).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func url(named name: String) -> URL? {
        installed().first { $0.deletingPathExtension().lastPathComponent == name }
    }

    /// Copies a skin into the library, replacing one with the same name. Checks it loads first.
    @discardableResult
    static func install(_ url: URL) throws -> URL {
        _ = try WszSkin(url: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL != url.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }
}
