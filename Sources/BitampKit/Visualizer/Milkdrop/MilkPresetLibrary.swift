import Foundation

/// The presets the Presets visual shows: the ones that come with Bitamp, then any `.milk`
/// files in ~/Library/Application Support/Bitamp/Presets. Presets that need their own HLSL
/// shaders run without them, as plain feedback and waves.
enum MilkPresetLibrary {
    struct Entry {
        let name: String
        let preset: MilkPreset
    }

    static var userFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bitamp/Presets", isDirectory: true)
    }

    private static var folders: [URL] {
        var folders: [URL] = []
        if let bundled = BasicPitch.modelURL(path: "Presets") { folders.append(bundled) }
        if let userFolder { folders.append(userFolder) }
        return folders
    }

    private static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "milk" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The names of the presets there are, without reading them.
    static func names() -> [String] {
        var seen = Set<String>()
        return folders.flatMap(files(in:)).map { $0.deletingPathExtension().lastPathComponent }.filter { seen.insert($0).inserted }
    }

    static func load() -> [Entry] {
        var entries: [Entry] = []
        for folder in folders {
            for file in files(in: folder) {
                if let preset = MilkPreset(contentsOf: file) { entries.append(Entry(name: file.deletingPathExtension().lastPathComponent, preset: preset)) }
            }
        }
        return entries
    }
}
