import AVFoundation
import BitampPakProtocol
import Foundation

/// `Bitamp --check-pak <folder.bitpak> [--setting key=value …]`: tries a Pak the way Bitamp
/// would, without installing it, and says what's wrong in words its author can act on.
/// It reads the manifest as installing does, starts the program as `PakConnection` does,
/// and asks it `hello`, `search ""`, then `track` and `resolve` for the first track. A notes
/// Pak is asked for notes on a song instead, and to stop a second time. Its settings are
/// the manifest's defaults plus any given; its cache is a temporary folder.
@MainActor
public final class PakCheck {
    /// Shorter than Bitamp's 30 seconds: a Pak that hasn't answered by now has most likely
    /// not flushed its output.
    static let timeout: TimeInterval = 10
    /// How long a notes Pak may go quiet, as in Bitamp: a lookup on the web takes a while.
    static let notesTimeout: TimeInterval = ExternalPak.notesTimeout
    /// What a notes Pak is asked about: a song any service should know something about.
    static let song = PakSongInfo(title: "Ode to Joy", artist: "Ludwig van Beethoven", album: "Symphony No. 9")

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

        if manifest.can(PakProtocol.notes) {
            if manifest.can(PakProtocol.browse) {
                warn("\(PakProtocol.manifestName): a Pak that writes notes has no music, so Bitamp doesn't browse it.")
            }
            if await checkNotes(connection, account: { account }) {
                await checkCancel(connection, settings: settings)
            }
            await checkShutdown(connection)
            return finish(manifest)
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
        if manifest.can(PakProtocol.browse) { await checkBrowse(connection) }
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
        for capability in manifest.capabilities ?? [] where !PakProtocol.knownCapabilities.contains(capability) {
            warn("\(PakProtocol.manifestName): this Bitamp doesn't know the capability “\(capability)”, so it ignores it.")
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
            warn("search \"\": no tracks. Bitamp shows this list when its Media Library opens, so it starts empty. "
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

    // MARK: - Browsing

    /// Walks the sidebar, each section, one place of each kind, and one cursor.
    private func checkBrowse(_ connection: PakConnection) async {
        func browse(_ location: PakBrowseLocation, cursor: String? = nil) async -> PakBrowsePage? {
            do {
                return try await connection.request(PakMethod.browse, PakMethod.Browse(location: location, cursor: cursor),
                                                    as: PakMethod.BrowseResult.self).page
            } catch {
                fail("browse \(describe(location)): \(explain(error))")
                return nil
            }
        }
        guard let root = await browse(.root) else { return }
        checkPage(root, .root)
        let sections = root.shelves.flatMap(\.items).compactMap { item -> PakPlaceInfo? in
            if case .place(let place) = item { return place }
            return nil
        }
        guard !sections.isEmpty else {
            fail("browse root: no sections. The manifest says the Pak browses, so the Media Library's sidebar would be empty. "
                + "List \"section\" places, or take \"browse\" out of the capabilities.")
            return
        }
        if sections.contains(where: { $0.kind != "section" }) {
            warn("browse root: the sidebar lists sections; other places there show as sections.")
        }
        pass("browse root: \(sections.count) section\(sections.count == 1 ? "" : "s") (\(sections.map(\.title).joined(separator: ", ")))")

        var opened: Set<String> = []
        var followedCursor = false
        func open(_ place: PakPlaceInfo) async -> PakBrowsePage? {
            guard opened.insert(place.id).inserted, let page = await browse(.place(place.id)) else { return nil }
            checkPage(page, .place(place.id))
            let tracks = page.shelves.flatMap(\.items).filter { if case .track = $0 { return true }; return false }.count
            let places = page.shelves.flatMap(\.items).count - tracks
            pass("browse \(place.kind) “\(place.title)”: \(tracks) track\(tracks == 1 ? "" : "s"), \(places) place\(places == 1 ? "" : "s")"
                + (page.header.map { ", header “\($0.title)”" } ?? "") + (page.cursor == nil ? "" : ", more after a cursor"))
            if let cursor = page.cursor, !followedCursor {
                followedCursor = true
                if let next = await browse(.place(place.id), cursor: cursor) {
                    checkPage(next, .place(place.id))
                    if next.cursor == cursor {
                        fail("browse “\(place.title)”: the next page gives the same cursor again, so it would never end.")
                    } else {
                        pass("browse “\(place.title)” after its cursor: \(next.shelves.flatMap(\.items).count) more")
                    }
                }
            }
            return page
        }
        // Every section, and the first album, artist and playlist found in them.
        var kindsSeen: Set<String> = ["section"]
        var toOpen: [PakPlaceInfo] = []
        for section in sections.prefix(12) {
            guard let page = await open(section) else { continue }
            for case .place(let place) in page.shelves.flatMap(\.items) where kindsSeen.insert(place.kind).inserted {
                toOpen.append(place)
            }
        }
        for place in toOpen { _ = await open(place) }

        if let search = await browse(.search("")) {
            checkPage(search, .search(""))
            pass("browse search \"\": \(search.shelves.flatMap(\.items).count) item\(search.shelves.flatMap(\.items).count == 1 ? "" : "s")")
        }
    }

    /// Ids, titles, kinds and covers on one page.
    private func checkPage(_ page: PakBrowsePage, _ location: PakBrowseLocation) {
        let at = "browse \(describe(location))"
        if let header = page.header {
            if header.title.isEmpty { fail("\(at): the header has no title.") }
            checkArtwork(header.artwork, "\(at), header")
        }
        for item in page.shelves.flatMap(\.items) {
            switch item {
            case .track(let track):
                if track.title.isEmpty { fail("\(at): track “\(track.id)” has no title.") }
                if track.id.isEmpty { fail("\(at): a track has no id.") }
                checkArtwork(track.artwork, "\(at), track “\(track.title)”")
            case .place(let place):
                if place.id.isEmpty { fail("\(at): “\(place.title)” has no id, so it can't be opened.") }
                if place.title.isEmpty { fail("\(at): the place “\(place.id)” has no title.") }
                if !PakPlaceInfo.kinds.contains(place.kind) {
                    warn("\(at): “\(place.title)” is a “\(place.kind)”, which Bitamp shows as a section. "
                        + "Kinds are \(PakPlaceInfo.kinds.sorted().joined(separator: ", ")).")
                }
                checkArtwork(place.artwork, "\(at), “\(place.title)”")
            }
        }
    }

    private func checkArtwork(_ artwork: PakArtworkInfo?, _ what: String) {
        guard let artwork else { return }
        if let path = artwork.file {
            if !FileManager.default.fileExists(atPath: path) { fail("\(what): the cover file \(path) isn't there.") }
        } else if let text = artwork.url {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
                fail("\(what): the cover's url “\(text)” isn't http or https.")
                return
            }
        } else {
            fail("\(what): the cover has neither a file nor a url.")
        }
    }

    private func describe(_ location: PakBrowseLocation) -> String {
        switch location {
        case .root: "root"
        case .place(let id): "“\(id)”"
        case .search(let term): "search \"\(term)\""
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

    // MARK: - Notes

    /// Asks for notes on `song` and looks at what comes back. False if nothing did.
    private func checkNotes(_ connection: PakConnection, account: () -> PakAccountState?) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        var firstWords: TimeInterval?
        var updates = 0
        var text = ""
        var citations: [PakCitation] = []
        let decoder = JSONDecoder()
        let what = "notes “\(Self.song.title)”"
        do {
            let result = try await connection.request(PakMethod.notes, PakMethod.Notes(song: Self.song), as: PakMethod.NotesResult.self,
                                                      timeout: Self.notesTimeout) { [weak self] line in
                guard let update = try? decoder.decode(PakUpdate<PakNotesUpdate>.self, from: line).update else {
                    self?.fail("\(what): an update isn't what Bitamp expects: \(String(decoding: line, as: UTF8.self))")
                    return
                }
                updates += 1
                if let words = update.text, !words.isEmpty {
                    text += words
                    if firstWords == nil { firstWords = ProcessInfo.processInfo.systemUptime - started }
                }
                citations += update.cite ?? []
            }
            report(account())
            text += result.text ?? ""
            citations += result.sources ?? []
        } catch {
            if account() == nil {
                fail("hello: \(explain(error))")
            } else {
                report(account())
                fail("\(what): \(explain(error))")
            }
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("\(what): no words came back, so the window would say “No notes came back.”")
            return false
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let total = ProcessInfo.processInfo.systemUptime - started
        var line = "\(what): \(words) word\(words == 1 ? "" : "s"), \(citations.count) source\(citations.count == 1 ? "" : "s"), "
            + String(format: "%.1f s", total)
        if updates == 0 {
            line += ", all in the answer. Send updates and the words appear as they're written."
        } else if let firstWords {
            line += String(format: " (first words after %.1f s, in %d update%@)", firstWords, updates, updates == 1 ? "" : "s")
        }
        pass(line)
        for citation in citations {
            guard let url = URL(string: citation.url), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
                warn("\(what): the source “\(citation.url)” isn't an http or https address, so Bitamp leaves it out.")
                continue
            }
            if citation.title.trimmingCharacters(in: .whitespaces).isEmpty {
                warn("\(what): the source \(citation.url) has no title, so Bitamp shows its address.")
            }
        }
        return true
    }

    /// Asks for notes again and cancels them, as Bitamp does when the song changes, then
    /// checks the Pak answers the next request promptly rather than finishing the notes first.
    private func checkCancel(_ connection: PakConnection, settings: [String: String]) async {
        let lookup = Task {
            try await connection.request(PakMethod.notes, PakMethod.Notes(song: Self.song), as: PakMethod.NotesResult.self,
                                         timeout: Self.notesTimeout) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(300))
        lookup.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await connection.request(PakMethod.configure, PakMethod.Configure(settings: settings), as: PakMethod.AccountResult.self)
        } catch {
            return fail("cancel: the next request after a cancel got no answer: \(explain(error))")
        }
        let waited = ProcessInfo.processInfo.systemUptime - started
        if (try? await lookup.value) != nil {
            pass("cancel: the notes came back before the cancel, so it wasn't needed")
        } else if waited > 2 {
            warn(String(format: "cancel: the next request waited %.1f s, so the Pak kept on with notes nobody wanted. ", waited)
                + "Stop when the request is cancelled (in Swift, when the task is).")
        } else {
            pass(String(format: "cancel: stopped, and answered the next request in %.1f s", waited))
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
