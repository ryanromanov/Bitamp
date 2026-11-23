import BitampPakProtocol
import Foundation
import Testing
@testable import BitampKit

@MainActor @Suite struct BundledPakTests {
    private func makePak(in folder: URL, id: String, version: String) throws -> URL {
        let pak = folder.appendingPathComponent("\(id).bitpak", isDirectory: true)
        try? FileManager.default.removeItem(at: pak)
        try FileManager.default.createDirectory(at: pak, withIntermediateDirectories: true)
        let program = pak.appendingPathComponent("run")
        try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let manifest = PakManifest(id: id, name: id, version: version, executable: "run")
        try JSONEncoder().encode(manifest).write(to: pak.appendingPathComponent("pak.json"))
        return pak
    }

    private struct Setup {
        let root: URL, inApp: URL, library: PakLibrary, defaults: UserDefaults
    }

    private func setup() throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        let inApp = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: inApp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "bundled-\(UUID().uuidString)")!
        return Setup(root: root, inApp: inApp, library: PakLibrary(folder: root.appendingPathComponent("Paks")), defaults: defaults)
    }

    @Test func installsABundledPakTheFirstTimeAndNotAgainAfterItIsRemoved() throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        _ = try makePak(in: s.inApp, id: "music", version: "1.0.0")

        s.library.installBundled(from: s.inApp, defaults: s.defaults)
        let first = s.library.installed()
        #expect(first.map(\.id) == ["music"])

        // The listener removes it; the next launch leaves it removed.
        try s.library.remove(try #require(first.first))
        s.library.installBundled(from: s.inApp, defaults: s.defaults)
        #expect(s.library.installed().isEmpty)
    }

    @Test func updatesOnlyAnInstalledPakToANewerVersion() throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        _ = try makePak(in: s.inApp, id: "music", version: "1.0.0")
        s.library.installBundled(from: s.inApp, defaults: s.defaults)

        _ = try makePak(in: s.inApp, id: "music", version: "1.1.0")
        s.library.installBundled(from: s.inApp, defaults: s.defaults)
        #expect(s.library.installed().first?.manifest.version == "1.1.0")

        // An older app doesn't take it back.
        _ = try makePak(in: s.inApp, id: "music", version: "1.0.5")
        s.library.installBundled(from: s.inApp, defaults: s.defaults)
        #expect(s.library.installed().first?.manifest.version == "1.1.0")
    }

    @Test func aPakAlreadyInstalledBeforeTheAppBroughtItIsNotReplacedByAnOlderOne() throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let installed = s.root.appendingPathComponent("Paks", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        _ = try makePak(in: installed, id: "music", version: "2.0.0")
        _ = try makePak(in: s.inApp, id: "music", version: "1.0.0")

        s.library.installBundled(from: s.inApp, defaults: s.defaults)
        #expect(s.library.installed().first?.manifest.version == "2.0.0")
    }

    @Test func aMissingFolderIsFine() throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        s.library.installBundled(from: nil, defaults: s.defaults)
        s.library.installBundled(from: s.root.appendingPathComponent("nowhere"), defaults: s.defaults)
        #expect(s.library.installed().isEmpty)
    }

    @Test func aManifestCanAskForANewerMacOS() {
        var manifest = PakManifest(id: "x", name: "X", version: "1", executable: "run")
        #expect(manifest.runsOnThisMac)
        manifest.minimumMacOS = "10.15"
        #expect(manifest.runsOnThisMac)
        manifest.minimumMacOS = "99.0"
        #expect(!manifest.runsOnThisMac)
        manifest.minimumMacOS = "nonsense"
        #expect(manifest.runsOnThisMac)
    }
}
