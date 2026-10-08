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
}

extension PakProvider {
    public func configure(_ context: PakContext) async throws -> PakAccountState { .connected }
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
    public static func serve<Lines: AsyncSequence>(
        _ provider: PakProvider, input: Lines, write: (String) -> Void
    ) async where Lines.Element == String {
        var context = PakContext(settings: [:], cacheDirectory: FileManager.default.temporaryDirectory)
        do {
            for try await line in input {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let data = Data(line.utf8)
                guard let header = try? decoder.decode(PakRequestHeader.self, from: data) else {
                    log("couldn't read a request: \(line)")
                    continue
                }
                let reply = await answer(header, data, provider, &context)
                write(reply)
                if header.method == PakMethod.shutdown { return }
            }
        } catch {
            log("input ended: \(error)")
        }
    }

    private static func answer(
        _ header: PakRequestHeader, _ data: Data, _ provider: PakProvider, _ context: inout PakContext
    ) async -> String {
        do {
            switch header.method {
            case PakMethod.hello:
                let hello = try params(PakMethod.Hello.self, data)
                context = PakContext(settings: hello.settings, cacheDirectory: URL(fileURLWithPath: hello.cacheDirectory))
                try? FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
                return encode(header.id, PakMethod.AccountResult(account: try await provider.configure(context)))
            case PakMethod.configure:
                context.settings = try params(PakMethod.Configure.self, data).settings
                return encode(header.id, PakMethod.AccountResult(account: try await provider.configure(context)))
            case PakMethod.search:
                let term = try params(PakMethod.Search.self, data).term
                return encode(header.id, PakMethod.SearchResult(tracks: try await provider.search(term)))
            case PakMethod.track:
                let id = try params(PakMethod.TrackID.self, data).id
                return encode(header.id, PakMethod.TrackResult(track: try await provider.track(id: id)))
            case PakMethod.resolve:
                let id = try params(PakMethod.TrackID.self, data).id
                return encode(header.id, PakMethod.ResolveResult(source: try await provider.resolve(id: id)))
            case PakMethod.shutdown:
                return encode(header.id, PakMethod.Empty())
            default:
                throw PakFailure("Unknown method \(header.method)")
            }
        } catch {
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
        let data = (try? encoder.encode(PakResponse(id: id, result: result))) ?? Data()
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
