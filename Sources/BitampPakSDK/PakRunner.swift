@_exported import BitampPakProtocol
import Foundation

/// What a third-party Pak written in Swift implements. `PakRunner.run` does the talking
/// to Bitamp; the Pak only answers questions about its music.
///
///     final class MyPak: PakProvider {
///         func search(_ term: String) async throws -> [PakTrackInfo] { … }
///         func track(id: String) async throws -> PakTrackInfo? { … }
///         func resolve(id: String) async throws -> PakSource { .url(streamURL(for: id)) }
///     }
///     PakRunner.run(MyPak())
public protocol PakProvider: AnyObject {
    /// Called first, and again whenever the user changes the settings. Check them here
    /// (sign in, reach the server) and say whether the Pak can play.
    func configure(_ context: PakContext) async throws -> PakAccountState
    func search(_ term: String) async throws -> [PakTrackInfo]
    /// One track by the id `search` gave it, or nil if it's gone.
    func track(id: String) async throws -> PakTrackInfo?
    /// Where the track's audio is: a local file, or a URL Bitamp downloads.
    func resolve(id: String) async throws -> PakSource
    /// What's at `location` for the Media Library, or more of it after the `cursor` an
    /// earlier page gave. Asked only if `pak.json` lists the `browse` capability. The root
    /// is the sidebar: shelves of `section` places. See docs/PAK-SDK.md.
    func browse(_ location: PakBrowseLocation, cursor: String?) async throws -> PakBrowsePage
    /// Notes about the song that's playing, written a piece at a time with `writer`, for a
    /// companion Pak. Asked only if `pak.json` lists the `notes` capability. Stop when the
    /// task is cancelled: Bitamp no longer wants them. See docs/PAK-SDK.md.
    func notes(for song: PakSongInfo, writer: PakNotesWriter) async throws

    // Playback, for a Pak whose manifest lists `playback` and declares protocol 3: it plays
    // every track itself, instead of handing Bitamp a file. Bitamp sends these in order, apart
    // from searches and browsing. Answer each as soon as the player has been told, and say
    // what really happens with the `PakPlaybackReporter` from `attach`. `load` may take a
    // while (preparing a stream); stop if the task is cancelled, because Bitamp has moved on.
    // See docs/PAK-SDK.md.

    /// The picture for an artwork `id` the Pak gave in a `PakArtworkInfo`, drawn into a file
    /// under `PakContext.cacheDirectory`, about `size` pixels square; nil if there's none. Asked
    /// for many at once, as a page of covers is shown, and alongside other requests, so keep
    /// how many draw at a time down. Stop if the task is cancelled.
    func artwork(id: String, size: Int) async throws -> URL?

    /// Called once, before the first request, with where to report what the player is doing.
    func attach(_ reporter: PakPlaybackReporter)
    /// Gets track `id` ready, stopped, and says what's known about it.
    func load(id: String) async throws -> PakPlaybackLoad
    /// Starts the loaded track from the top.
    func play() async throws
    func pause() async throws
    /// Continues after `pause`.
    func resume() async throws
    func stop() async throws
    func seek(to seconds: Double) async throws
}

/// What `load` says about the track it prepared.
public typealias PakPlaybackLoad = PakMethod.LoadResult

extension PakProvider {
    public func configure(_ context: PakContext) async throws -> PakAccountState { .connected }

    // A companion Pak, which only writes notes, has no music to search, describe or play.
    public func search(_ term: String) async throws -> [PakTrackInfo] { [] }
    public func track(id: String) async throws -> PakTrackInfo? { nil }
    public func resolve(id: String) async throws -> PakSource { throw PakFailure("This Pak has no music to play.") }

    public func notes(for song: PakSongInfo, writer: PakNotesWriter) async throws {
        throw PakFailure("This Pak doesn't write notes.")
    }

    public func artwork(id: String, size: Int) async throws -> URL? { nil }
    public func attach(_ reporter: PakPlaybackReporter) {}
    public func load(id: String) async throws -> PakPlaybackLoad { throw PakFailure("This Pak doesn't play its own audio.") }
    public func play() async throws { throw PakFailure("This Pak doesn't play its own audio.") }
    public func pause() async throws { throw PakFailure("This Pak doesn't play its own audio.") }
    public func resume() async throws { throw PakFailure("This Pak doesn't play its own audio.") }
    public func stop() async throws { throw PakFailure("This Pak doesn't play its own audio.") }
    public func seek(to seconds: Double) async throws { throw PakFailure("This Pak doesn't play its own audio.") }

    /// Search's tracks for a search, an empty sidebar, and nothing to open.
    public func browse(_ location: PakBrowseLocation, cursor: String?) async throws -> PakBrowsePage {
        switch location {
        case .search(let term):
            guard cursor == nil else { return PakBrowsePage() }
            return PakBrowsePage(shelves: [PakShelfInfo(items: try await search(term).map(PakItemInfo.track))])
        case .root:
            return PakBrowsePage()
        case .place(let id):
            throw PakFailure("Nothing called \(id) here.")
        }
    }
}

/// The user's settings and a folder the Pak can keep files in.
public struct PakContext: Sendable {
    public var settings: [String: String]
    public var cacheDirectory: URL

    public init(settings: [String: String], cacheDirectory: URL) {
        self.settings = settings
        self.cacheDirectory = cacheDirectory
    }
}

/// Sends Bitamp the notes for one request as they're written. Bitamp shows each piece as
/// it arrives. Safe to call from any task; after the request is cancelled or answered,
/// writing does nothing.
public final class PakNotesWriter: @unchecked Sendable {
    private let id: Int
    private let output: PakRunner.Output
    private let lock = NSLock()
    private var open = true

    init(id: Int, output: PakRunner.Output) {
        self.id = id
        self.output = output
    }

    /// More words, added to what's been written. Plain text; Bitamp wraps it, and a blank
    /// line starts a new paragraph.
    public func write(_ text: String) {
        send(.text(text))
    }

    /// The sources of the words written just before. Bitamp numbers them and marks the words.
    public func cite(_ citations: [PakCitation]) {
        guard !citations.isEmpty else { return }
        send(.cite(citations))
    }

    private func send(_ update: PakNotesUpdate) {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        output.write(PakRunner.encode(PakUpdate(id: id, update: update)))
    }

    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}

/// Tells Bitamp what a `playback` Pak's player is doing: playing, paused or stopped and
/// where it is, when a track ends, and when it fails. Safe to call from any thread. Report
/// when anything changes, and every half second or so while playing, so Bitamp's clock
/// follows the player's. Events are about the track most recently loaded.
public final class PakPlaybackReporter: @unchecked Sendable {
    private let output: PakRunner.Output
    private let lock = NSLock()
    private var track: String?

    init(output: PakRunner.Output) {
        self.output = output
    }

    /// Set by the runner when a `load` arrives, so events name the track they're about.
    func loading(_ id: String) {
        lock.lock()
        track = id
        lock.unlock()
    }

    public func report(_ state: PakPlayerState, position: Double, duration: Double? = nil) {
        send(PakPlaybackEvent(event: PakPlaybackEvent.state, track: currentTrack, state: state, position: position, duration: duration))
    }

    /// The track played to its end and the player has stopped.
    public func ended() {
        send(PakPlaybackEvent(event: PakPlaybackEvent.ended, track: currentTrack))
    }

    /// The track can't play, or stopped without being asked to. `advice` is what the listener can try.
    public func failed(_ message: String, advice: String? = nil) {
        send(PakPlaybackEvent(event: PakPlaybackEvent.error, track: currentTrack, message: message, advice: advice))
    }

    private var currentTrack: String? {
        lock.lock()
        defer { lock.unlock() }
        return track
    }

    private func send(_ event: PakPlaybackEvent) {
        output.write(PakRunner.encode(event))
    }
}

/// Throw this to send Bitamp a message it can show.
public struct PakFailure: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum PakRunner {
    /// Answers Bitamp's requests until it asks the Pak to stop or closes the pipe, then exits.
    ///
    /// The main thread runs the main run loop, which a Pak that plays audio needs for its
    /// player's callbacks and timers; requests are answered on other threads.
    public static func run(_ provider: PakProvider) -> Never {
        Task.detached {
            await serve(provider, input: FileHandle.standardInput.bytes.lines) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            exit(0)
        }
        // A run loop with nothing to wait for returns at once, so give it a timer that never fires.
        let idle = Timer(timeInterval: 1e9, repeats: true) { _ in }
        RunLoop.main.add(idle, forMode: .common)
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// The request loop, separate from standard input and output so it can be tested.
    ///
    /// Requests are answered one at a time, in order, so a Pak never has two running at
    /// once, with two exceptions. `artwork` requests run alongside everything, each in its own
    /// task. Playback commands (`load`, `play`, `pause`, `resume`, `stop` and `seek`) go in a
    /// line of their own, in order among themselves, so a slow search doesn't hold up a pause. A `cancel` is read while a request runs, and cancels it (or
    /// drops it, if it hasn't started); a cancelled request isn't answered. `shutdown`
    /// cancels whatever runs.
    public static func serve<Lines: AsyncSequence>(
        _ provider: PakProvider, input: Lines, write: @escaping (String) -> Void
    ) async where Lines.Element == String {
        let output = Output(write)
        let running = Running()
        let reporter = PakPlaybackReporter(output: output)
        let context = ContextBox()
        provider.attach(reporter)
        let (requests, queue) = AsyncStream<(PakRequestHeader, Data)>.makeStream()
        let (playbackRequests, playbackQueue) = AsyncStream<(PakRequestHeader, Data)>.makeStream()
        func worker(_ requests: AsyncStream<(PakRequestHeader, Data)>) -> Task<Void, Never> {
            Task {
                for await (header, data) in requests {
                    guard let task = running.start(header.id, { Task { await answer(header, data, provider, context, output, reporter) } })
                    else { continue }
                    let reply = await task.value
                    if running.finish(header.id), let reply { output.write(reply) }
                    if header.method == PakMethod.shutdown { return }
                }
            }
        }
        let general = worker(requests)
        let playback = worker(playbackRequests)
        // Artwork requests run alongside everything, each in its own task.
        let artwork = Tasks()
        func concurrently(_ header: PakRequestHeader, _ data: Data) {
            guard let task = running.start(header.id, { Task { await answer(header, data, provider, context, output, reporter) } })
            else { return }
            artwork.add(Task {
                let reply = await task.value
                if running.finish(header.id), let reply { output.write(reply) }
            })
        }
        do {
            for try await line in input {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let data = Data(line.utf8)
                guard let header = try? decoder.decode(PakRequestHeader.self, from: data) else {
                    log("couldn't read a request: \(line)")
                    continue
                }
                if header.method == PakMethod.cancel {
                    if let cancel = try? params(PakMethod.Cancel.self, data) { running.cancel(cancel.id) }
                    continue
                }
                if header.method == PakMethod.shutdown { running.cancelCurrent() }
                if PakMethod.playbackMethods.contains(header.method) {
                    playbackQueue.yield((header, data))
                } else if header.method == PakMethod.artwork {
                    concurrently(header, data)
                } else {
                    queue.yield((header, data))
                }
                if header.method == PakMethod.shutdown { break }
            }
        } catch {
            log("input ended: \(error)")
        }
        queue.finish()
        playbackQueue.finish()
        await general.value
        await playback.value
        await artwork.finished()
    }

    /// Tasks started and not yet waited for.
    final class Tasks: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            tasks.append(task)
            lock.unlock()
        }

        func finished() async {
            lock.lock()
            let all = tasks
            tasks = []
            lock.unlock()
            for task in all { await task.value }
        }
    }

    /// The requests running now, and those cancelled before they started.
    final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var current: [Int: (task: Task<String?, Never>, cancelled: Bool)] = [:]
        private var cancelled: Set<Int> = []

        /// Starts a request, unless it was cancelled while it waited.
        func start(_ id: Int, _ make: () -> Task<String?, Never>) -> Task<String?, Never>? {
            lock.lock()
            defer { lock.unlock() }
            guard cancelled.remove(id) == nil else { return nil }
            let task = make()
            current[id] = (task, false)
            return task
        }

        /// Whether the request finished without being cancelled, so it gets an answer.
        func finish(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let answered = current[id]?.cancelled == false
            current[id] = nil
            return answered
        }

        func cancel(_ id: Int) {
            lock.lock()
            defer { lock.unlock() }
            if current[id] != nil {
                current[id]?.cancelled = true
                current[id]?.task.cancel()
            } else {
                cancelled.insert(id)
            }
        }

        func cancelCurrent() {
            lock.lock()
            defer { lock.unlock() }
            for id in Array(current.keys) {
                current[id]?.cancelled = true
                current[id]?.task.cancel()
            }
        }
    }

    /// Writes whole lines, one at a time, whichever task sends them.
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let write: (String) -> Void
        init(_ write: @escaping (String) -> Void) { self.write = write }
        func write(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            write(line)
        }
    }

    final class ContextBox: @unchecked Sendable {
        var context = PakContext(settings: [:], cacheDirectory: FileManager.default.temporaryDirectory)
    }

    /// The answer to one request, or nil if it was cancelled.
    private static func answer(
        _ header: PakRequestHeader, _ data: Data, _ provider: PakProvider, _ box: ContextBox, _ output: Output,
        _ reporter: PakPlaybackReporter
    ) async -> String? {
        do {
            switch header.method {
            case PakMethod.hello:
                let hello = try params(PakMethod.Hello.self, data)
                box.context = PakContext(settings: hello.settings, cacheDirectory: URL(fileURLWithPath: hello.cacheDirectory))
                try? FileManager.default.createDirectory(at: box.context.cacheDirectory, withIntermediateDirectories: true)
                return encode(header.id, PakMethod.AccountResult(account: try await provider.configure(box.context)))
            case PakMethod.configure:
                box.context.settings = try params(PakMethod.Configure.self, data).settings
                return encode(header.id, PakMethod.AccountResult(account: try await provider.configure(box.context)))
            case PakMethod.search:
                let term = try params(PakMethod.Search.self, data).term
                return encode(header.id, PakMethod.SearchResult(tracks: try await provider.search(term)))
            case PakMethod.track:
                let id = try params(PakMethod.TrackID.self, data).id
                return encode(header.id, PakMethod.TrackResult(track: try await provider.track(id: id)))
            case PakMethod.resolve:
                let id = try params(PakMethod.TrackID.self, data).id
                return encode(header.id, PakMethod.ResolveResult(source: try await provider.resolve(id: id)))
            case PakMethod.browse:
                let browse = try params(PakMethod.Browse.self, data)
                return encode(header.id, PakMethod.BrowseResult(page: try await provider.browse(browse.location, cursor: browse.cursor)))
            case PakMethod.notes:
                let song = try params(PakMethod.Notes.self, data).song
                let writer = PakNotesWriter(id: header.id, output: output)
                defer { writer.close() }
                try await provider.notes(for: song, writer: writer)
                try Task.checkCancellation()
                writer.close()
                return encode(header.id, PakMethod.NotesResult())
            case PakMethod.artwork:
                let request = try params(PakMethod.Artwork.self, data)
                let file = try await provider.artwork(id: request.id, size: request.size)
                return encode(header.id, PakMethod.ArtworkResult(file: file?.path))
            case PakMethod.load:
                let id = try params(PakMethod.TrackID.self, data).id
                reporter.loading(id)
                return encode(header.id, try await provider.load(id: id))
            case PakMethod.play:
                try await provider.play()
                return encode(header.id, PakMethod.Empty())
            case PakMethod.pause:
                try await provider.pause()
                return encode(header.id, PakMethod.Empty())
            case PakMethod.resume:
                try await provider.resume()
                return encode(header.id, PakMethod.Empty())
            case PakMethod.stop:
                try await provider.stop()
                return encode(header.id, PakMethod.Empty())
            case PakMethod.seek:
                try await provider.seek(to: try params(PakMethod.Seek.self, data).seconds)
                return encode(header.id, PakMethod.Empty())
            case PakMethod.shutdown:
                return encode(header.id, PakMethod.Empty())
            default:
                throw PakFailure("Unknown method \(header.method)")
            }
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return encodeError(header.id, message)
        }
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func params<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(PakRequest<T>.self, from: data).params
    }

    private static func encode<T: Codable>(_ id: Int, _ result: T) -> String {
        encode(PakResponse(id: id, result: result))
    }

    static func encode<T: Encodable>(_ message: T) -> String {
        let data = (try? encoder.encode(message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeError(_ id: Int, _ message: String) -> String {
        let data = (try? encoder.encode(PakResponse<PakMethod.Empty>(id: id, error: PakError(message: message)))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes to standard error, which Bitamp keeps in its log.
    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
