import AVFoundation
import BitampPakProtocol
import Foundation

/// `Bitamp --check-pak <folder.bitpak> [--setting key=value …]`: tries a Pak the way Bitamp
/// would, without installing it, and says what's wrong in words its author can act on.
/// It reads the manifest as installing does, starts the program as `PakConnection` does,
/// and asks it `hello`, `search ""`, then `track` and `resolve` for the first track. Its
/// settings are the manifest's defaults plus any given; its cache is a temporary folder.
@MainActor
public final class PakCheck {
    /// Shorter than Bitamp's 30 seconds: a Pak that hasn't answered by now has most likely
    /// not flushed its output.
    static let timeout: TimeInterval = 10

    private let folder: URL
    private let extraSettings: [String: String]
    private let reservedIDs: Set<String>
    private let output: (String) -> Void
    private(set) var problems = 0

    init(folder: URL, settings: [String: String] = [:], reservedIDs: Set<String> = [], output: @escaping (String) -> Void) {
        self.folder = folder
        self.extraSettings = settings
        self.reservedIDs = reservedIDs
        self.output = output
    }

    /// Runs the check from the command line and exits: 0 if the Pak is fine, 1 if not, 64
    /// for a bad command line. `arguments` are those after `--check-pak`.
    public nonisolated static func main(_ arguments: [String], reservedIDs: Set<String>) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var path: String?
        var settings: [String: String] = [:]
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--setting", let pair = rest.popFirst(), let equals = pair.firstIndex(of: "=") {
                settings[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            } else if path == nil, !argument.hasPrefix("-") {
                path = argument
            } else {
                path = nil
                break
            }
        }
        guard let path else {
            FileHandle.standardError.write(Data("usage: Bitamp --check-pak <folder.bitpak> [--setting key=value …]\n".utf8))
            exit(64)
        }
        Task { @MainActor in
            let check = PakCheck(folder: URL(fileURLWithPath: path), settings: settings, reservedIDs: reservedIDs) { print($0) }
            exit(await check.run() ? 0 : 1)
        }
        // Not dispatchMain(): that parks the main thread, and main-queue blocks then run on
        // another, which `MainActor.assumeIsolated` in PakConnection rightly refuses.
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// Whether the Pak passed.
    func run() async -> Bool {
        guard let manifest = checkManifest() else { return finish(nil) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("BitampPakCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        var settings: [String: String] = [:]
        for setting in manifest.settings ?? [] { settings[setting.key] = setting.defaultValue }
        settings.merge(extraSettings) { $1 }
        let connection = PakConnection(
            executable: folder.appendingPathComponent(manifest.executable), name: manifest.name, timeout: Self.timeout,
            hello: {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                return (PakMethod.hello, PakMethod.Hello(protocol: PakProtocol.version, settings: settings, cacheDirectory: cache.path))
            })
        var account: PakAccountState?
        connection.onHello = { account = $0.account }
        connection.onLog = { [output] in output("    │ \($0)") }
        connection.onUnexpectedOutput = { [weak self] line in
            self?.fail("It printed a line that isn't an answer: \(line)\n"
                + "      Only answers go to standard output. Print anything else to standard error.")
        }

        // hello is sent on the first request, before search.
        let tracks: [PakTrackInfo]
        do {
            let result = try await connection.request(PakMethod.search, PakMethod.Search(term: ""), as: PakMethod.SearchResult.self)
            report(account)
            tracks = result.tracks
        } catch {
            if account == nil {
                fail("hello: \(explain(error))")
            } else {
                report(account)
                fail("search \"\": \(explain(error))")
            }
            connection.shutdown()
            return finish(manifest)
        }
        checkTracks(tracks, manifest)
        if let first = tracks.first {
            await checkTrack(first, connection)
            await checkResolve(first, connection)
        }
        await checkShutdown(connection)
        return finish(manifest)
    }

    // MARK: - Steps

    private func checkManifest() -> PakManifest? {
        if !PakLibrary.isPak(folder) {
            warn("The folder's name doesn't end in .bitpak, so Bitamp won't recognize it to install.")
        }
        let manifest: PakManifest
        do {
            manifest = try PakLibrary.manifest(in: folder)
        } catch {
            fail("\(PakProtocol.manifestName): \(error.localizedDescription)")
            return nil
        }
        if reservedIDs.contains(manifest.id) {
            fail("\(PakProtocol.manifestName): \(PakLibrary.InstallError.takenID(manifest.id).localizedDescription)")
        }
        var keys: Set<String> = []
        for setting in manifest.settings ?? [] {
            if !keys.insert(setting.key).inserted { fail("Settings: “\(setting.key)” is listed twice.") }
            if setting.kind == .choice {
                let options = setting.options ?? []
                if options.isEmpty { fail("Settings: the choice “\(setting.key)” has no options.") }
                if let value = setting.defaultValue, !options.contains(value) {
                    fail("Settings: “\(setting.key)” defaults to “\(value)”, which isn't one of its options.")
                }
            }
        }
        pass("\(PakProtocol.manifestName): \(manifest.name) Pak \(manifest.version), id “\(manifest.id)”, runs \(manifest.executable)")
        return manifest
    }

    private func report(_ account: PakAccountState?) {
        guard let account else { return }
        let message = account.message.map { ": \($0)" } ?? ""
        switch account.state {
        case .connected: pass("hello: connected\(message)")
        case .limited: pass("hello: limited\(message)")
        case .disconnected:
            warn("hello: disconnected\(message). Bitamp will ask the listener to set the Pak up. "
                + "To check with settings filled in, add --setting key=value.")
        }
    }

    private func checkTracks(_ tracks: [PakTrackInfo], _ manifest: PakManifest) {
        guard !tracks.isEmpty else {
            warn("search \"\": no tracks. Bitamp shows this list when its search opens, so it starts empty. "
                + "The rest of the check needs a track.")
            return
        }
        pass("search \"\": \(tracks.count) track\(tracks.count == 1 ? "" : "s"), first “\(tracks[0].title)”")
        var seen: Set<String> = []
        for track in tracks {
            if track.title.isEmpty { fail("search: track “\(track.id)” has no title.") }
            if !seen.insert(track.id).inserted { fail("search: the id “\(track.id)” is used by more than one track.") }
            if ExternalPak.trackID(ExternalPak.trackURL(track.id, pak: manifest.id), pak: manifest.id) != track.id {
                fail("search: the id “\(track.id)” can't be saved in a playlist. Use a non-empty id.")
            }
        }
    }

    private func checkTrack(_ first: PakTrackInfo, _ connection: PakConnection) async {
        do {
            let result = try await connection.request(PakMethod.track, PakMethod.TrackID(id: first.id), as: PakMethod.TrackResult.self)
            guard let track = result.track else {
                return fail("track “\(first.id)”: not found. Bitamp asks this when it reopens a playlist, "
                    + "so answer for every id search gives.")
            }
            if track.id == first.id {
                pass("track “\(first.id)”: “\(track.title)”")
            } else {
                fail("track “\(first.id)”: answered with a different id, “\(track.id)”.")
            }
        } catch {
            fail("track “\(first.id)”: \(explain(error))")
        }
    }

    private func checkResolve(_ first: PakTrackInfo, _ connection: PakConnection) async {
        let source: PakSource
        do {
            source = try await connection.request(PakMethod.resolve, PakMethod.TrackID(id: first.id), as: PakMethod.ResolveResult.self).source
        } catch {
            return fail("resolve “\(first.id)”: \(explain(error))")
        }
        if let path = source.file {
            guard path.hasPrefix("/") else { return fail("resolve “\(first.id)”: the file “\(path)” has to be an absolute path.") }
            guard FileManager.default.fileExists(atPath: path) else { return fail("resolve “\(first.id)”: there's no file at \(path).") }
            do {
                _ = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                pass("resolve “\(first.id)”: file \(path)")
            } catch {
                fail("resolve “\(first.id)”: macOS can't play \(path) (\(error.localizedDescription)).")
            }
        } else if let text = source.url {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
                return fail("resolve “\(first.id)”: “\(text)” isn't an http or https URL.")
            }
            pass("resolve “\(first.id)”: \(url.absoluteString) (not downloaded)")
        } else {
            fail("resolve “\(first.id)”: the source has neither a file nor a url.")
        }
    }

    private func checkShutdown(_ connection: PakConnection) async {
        connection.shutdown()
        // Bitamp stops a Pak itself 2 seconds after asking.
        for _ in 0..<18 where connection.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if connection.isRunning {
            fail("shutdown: still running 2 seconds after being asked to stop. Exit after answering shutdown, "
                + "or when standard input closes.")
        } else {
            pass("shutdown: exited")
        }
    }

    // MARK: - Reporting

    private func explain(_ error: Error) -> String {
        switch error as? PakConnection.Failure {
        case .timedOut:
            return "no answer within \(Int(Self.timeout)) seconds. If the program printed one, it probably didn't flush "
                + "standard output; Bitamp waits for each whole line. In Python, print(…, flush=True)."
        case .exited:
            return "the program stopped running before it answered. What it printed to standard error is above."
        case .unreadable(let method):
            return "the answer to \(method) isn't what Bitamp expects. Check its fields against docs/PAK-SDK.md."
        default:
            return error.localizedDescription
        }
    }

    private func pass(_ line: String) { output("✓ \(line)") }
    private func warn(_ line: String) { output("! \(line)") }
    private func fail(_ line: String) {
        problems += 1
        output("✗ \(line)")
    }

    private func finish(_ manifest: PakManifest?) -> Bool {
        let name = manifest.map { "The \($0.name) Pak" } ?? "This Pak"
        if problems == 0 {
            output("\(name) looks good. Double-click it to install it.")
        } else {
            output("\(name) has \(problems) problem\(problems == 1 ? "" : "s").")
        }
        return problems == 0
    }
}
