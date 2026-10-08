import BitampPakProtocol
import Foundation

/// The third-party Paks installed in `~/Library/Application Support/Bitamp/Paks`, one
/// `.bitpak` folder each.
@MainActor
final class PakLibrary {
    enum InstallError: LocalizedError {
        case noManifest
        case unreadableManifest(String)
        case badID(String)
        case newerProtocol(Int)
        case missingProgram(String)
        case takenID(String)

        var errorDescription: String? {
            switch self {
            case .noManifest: return "It has no \(PakProtocol.manifestName)."
            case .unreadableManifest(let reason): return "Its \(PakProtocol.manifestName) couldn't be read: \(reason)"
            case .badID(let id): return "Its id, “\(id)”, has to be lowercase letters, digits and hyphens."
            case .newerProtocol(let version): return "It needs a newer Bitamp (Pak protocol \(version))."
            case .missingProgram(let path): return "Its program, “\(path)”, is missing or can't be run."
            case .takenID(let id): return "A Pak built into Bitamp already uses the id “\(id)”."
            }
        }
    }

    nonisolated static let pathExtension = "bitpak"

    let folder: URL
    let settings: PakSettingsStore

    init(folder: URL? = nil, settings: PakSettingsStore? = nil) {
        self.folder = folder ?? Self.defaultFolder
        self.settings = settings ?? PakSettingsStore()
    }

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bitamp/Paks", isDirectory: true)
    }

    nonisolated static func isPak(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == pathExtension
    }

    /// Every installed Pak that reads correctly, by name.
    func installed() -> [ExternalPak] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.filter(Self.isPak).compactMap { bundle in
            do {
                return ExternalPak(manifest: try Self.manifest(in: bundle), folder: bundle, settings: settings)
            } catch {
                NSLog("Bitamp: skipping the Pak at \(bundle.path): \(error.localizedDescription)")
                return nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads and checks a `.bitpak` folder's manifest.
    static func manifest(in bundle: URL) throws -> PakManifest {
        let file = bundle.appendingPathComponent(PakProtocol.manifestName)
        guard let data = try? Data(contentsOf: file) else { throw InstallError.noManifest }
        let manifest: PakManifest
        do {
            manifest = try JSONDecoder().decode(PakManifest.self, from: data)
        } catch {
            throw InstallError.unreadableManifest(String(describing: error))
        }
        guard PakManifest.isValidID(manifest.id) else { throw InstallError.badID(manifest.id) }
        guard manifest.protocol <= PakProtocol.version else { throw InstallError.newerProtocol(manifest.protocol) }
        // The program has to be inside the folder.
        let program = bundle.appendingPathComponent(manifest.executable).standardizedFileURL
        guard program.path.hasPrefix(bundle.standardizedFileURL.path + "/"),
              FileManager.default.isExecutableFile(atPath: program.path)
        else { throw InstallError.missingProgram(manifest.executable) }
        return manifest
    }

    /// Copies a `.bitpak` in, replacing an installed one with the same id (an update).
    /// The user has said they trust it by now, so the download quarantine comes off.
    @discardableResult
    func install(_ bundle: URL, reservedIDs: Set<String>) throws -> PakManifest {
        let manifest = try Self.manifest(in: bundle)
        guard !reservedIDs.contains(manifest.id) else { throw InstallError.takenID(manifest.id) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(manifest.id).\(Self.pathExtension)", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: bundle, to: destination)
        Self.removeQuarantine(destination)
        return manifest
    }

    func remove(_ pak: ExternalPak) throws {
        settings.remove(pak.manifest)
        try FileManager.default.removeItem(at: pak.folder)
        try? FileManager.default.removeItem(at: pak.cacheDirectory)
    }

    private static func removeQuarantine(_ url: URL) {
        let paths = [url.path] + (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? [])
            .map { url.appendingPathComponent($0).path }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
}
