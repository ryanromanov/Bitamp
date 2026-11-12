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
}

extension PakProvider {
    public func configure(_ context: PakContext) async throws -> PakAccountState { .connected }

    // A companion Pak, which only writes notes, has no music to search, describe or play.
    public func search(_ term: String) async throws -> [PakTrackInfo] { [] }
    public func track(id: String) async throws -> PakTrackInfo? { nil }
    public func resolve(id: String) async throws -> PakSource { throw PakFailure("This Pak has no music to play.") }

    public func notes(for song: PakSongInfo, writer: PakNotesWriter) async throws {
        throw PakFailure("This Pak doesn't write notes.")
    }

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

/// Throw this to send Bitamp a message it can show.
public struct PakFailure: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum PakRunner {
    /// Answers Bitamp's requests until it asks the Pak to stop or closes the pipe, then exits.
    public static func run(_ provider: PakProvider) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task {
            await serve(provider, input: FileHandle.standardInput.bytes.lines) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// The request loop, separate from standard input and output so it can be tested.
    ///
    /// Requests are answered one at a time, in order, so a Pak never has two running at
    /// once. A `cancel` is read while a request runs, and cancels it (or drops it, if it
    /// hasn't started); a cancelled request isn't answered. `shutdown` cancels whatever runs.
    public static func serve<Lines: AsyncSequence>(
        _ provider: PakProvider, input: Lines, write: @escaping (String) -> Void
    ) async where Lines.Element == String {
        let output = Output(write)
        let running = Running()
        let (requests, queue) = AsyncStream<(PakRequestHeader, Data)>.makeStream()
        let worker = Task {
            let context = ContextBox()
            for await (header, data) in requests {
                guard let task = running.start(header.id, { Task { await answer(header, data, provider, context, output) } })
                else { continue }
                let reply = await task.value
                if running.finish(header.id), let reply { output.write(reply) }
                if header.method == PakMethod.shutdown { return }
            }
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
                queue.yield((header, data))
                if header.method == PakMethod.shutdown { break }
            }
        } catch {
            log("input ended: \(error)")
        }
        queue.finish()
        await worker.value
    }

    /// The request running now, and those cancelled before they started.
    final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var current: (id: Int, task: Task<String?, Never>, cancelled: Bool)?
        private var cancelled: Set<Int> = []

        /// Starts a request, unless it was cancelled while it waited.
        func start(_ id: Int, _ make: () -> Task<String?, Never>) -> Task<String?, Never>? {
            lock.lock()
            defer { lock.unlock() }
            guard cancelled.remove(id) == nil else { return nil }
            let task = make()
            current = (id, task, false)
            return task
        }

        /// Whether the request finished without being cancelled, so it gets an answer.
        func finish(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let answered = current?.id == id && current?.cancelled == false
            current = nil
            return answered
        }

        func cancel(_ id: Int) {
            lock.lock()
            defer { lock.unlock() }
            if current?.id == id {
                current?.cancelled = true
                current?.task.cancel()
            } else {
                cancelled.insert(id)
            }
        }

        func cancelCurrent() {
            lock.lock()
            defer { lock.unlock() }
            current?.cancelled = true
            current?.task.cancel()
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
        _ header: PakRequestHeader, _ data: Data, _ provider: PakProvider, _ box: ContextBox, _ output: Output
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
