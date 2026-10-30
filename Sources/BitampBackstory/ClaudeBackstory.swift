import BitampPakKit
import Foundation

/// Liner notes from Claude, with web search so they rest on real pages and say which.
/// Plain HTTPS to the Messages API, streamed, with the user's own key.
public struct ClaudeBackstory: BackstoryService {
    public enum Model: String, CaseIterable, Sendable {
        /// The default: accurate and about 4¢ a song in the spike.
        case sonnet = "claude-sonnet-5-5"
        /// Richer notes, for two to four times the price.
        case opus = "claude-opus-5-5"
    }

    let key: String
    let model: Model
    let session: URLSession

    public init(key: String, model: Model = .sonnet, session: URLSession = .shared) {
        self.key = key
        self.model = model
        self.session = session
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let system = """
    You write short liner notes for the song a person is listening to in a music player.

    Write at most two short paragraphs, 120 words in all, in plain text with no headings, \
    lists, emphasis or other markdown. Say something a listener would enjoy knowing: how and \
    when it was made, who played on it, what it's about, samples, covers, or how it was \
    received.

    Use web search, and state only facts the search results support about this exact \
    recording. If you can't find reliable information about it, say so in one sentence and \
    stop; never guess, and never fill in from another song on the same album or a \
    similar-sounding one.
    """

    static func prompt(for track: PakNowPlaying) -> String {
        var prompt = "Now playing: \"\(track.title)\""
        prompt += track.artist.map { " by \($0)" } ?? " (artist unknown)"
        if let album = track.album { prompt += ", from the album \"\(album)\"" }
        return prompt + "."
    }

    /// The request's body. Web search is called directly: with dynamic filtering the
    /// results pass through code first, and the notes come back citing nothing.
    static func body(for track: PakNowPlaying, model: Model) -> [String: Any] {
        [
            "model": model.rawValue,
            "max_tokens": 4000,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": prompt(for: track)]],
            "output_config": ["effort": "medium"],
            "tools": [[
                "type": "web_search_20260318", "name": "web_search",
                "max_uses": 2, "allowed_callers": ["direct"],
            ]],
            // If a safety check declines, another model answers instead.
            "fallbacks": "default",
        ]
    }

    func request(for track: PakNowPlaying) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: track, model: model))
        return request
    }

    public func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        let request = request(for: track)
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes where body.count < 16_384 { body.append(byte) }
                        throw Self.error(status: status, body: body)
                    }
                    var stream = ClaudeStream()
                    for try await line in bytes.lines {
                        for update in try stream.feed(line) { continuation.yield(update) }
                    }
                    try stream.finish()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as BackstoryError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: BackstoryError.failed("Couldn't reach Claude: \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What an unsuccessful reply means.
    static func error(status: Int, body: Data) -> BackstoryError {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String
        switch (status, error?["type"] as? String) {
        case (401, _), (_, "authentication_error"):
            return .badKey
        case (429, _), (_, "rate_limit_error"):
            return .limited("Claude says there have been too many requests. Try again in a minute.")
        case (_, "overloaded_error"), (500..., _):
            return .unavailable("Claude is busy right now. Try again in a moment.")
        case (400, _) where message?.localizedCaseInsensitiveContains("credit") == true:
            return .limited("The Claude account is out of credit.")
        default:
            return .failed(message.map { "Claude: \($0)" } ?? "Claude answered with an error (\(status)).")
        }
    }
}

/// Reads the Messages API's server-sent events: words as they arrive, and each text
/// block's citations once it ends.
struct ClaudeStream {
    /// The citations of each text block still open, by its index.
    private var citations: [Int: [BackstorySource]] = [:]
    private var stopReason: String?
    private var wroteText = false

    mutating func feed(_ line: String) throws -> [BackstoryUpdate] {
        guard line.hasPrefix("data:"),
              let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
        else { return [] }
        let index = event["index"] as? Int ?? -1
        switch event["type"] as? String {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" else { return [] }
            citations[index] = (block["citations"] as? [[String: Any]] ?? []).compactMap(Self.source)
            return text(block["text"] as? String)
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                return text(delta["text"] as? String)
            case "citations_delta":
                if let citation = delta["citation"] as? [String: Any], let source = Self.source(citation) {
                    citations[index, default: []].append(source)
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let sources = citations.removeValue(forKey: index), !sources.isEmpty else { return [] }
            var unique: [BackstorySource] = []
            for source in sources where !unique.contains(where: { $0.url == source.url }) { unique.append(source) }
            return [.cite(unique)]
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            return []
        case "error":
            let error = event["error"] as? [String: Any]
            let body = (try? JSONSerialization.data(withJSONObject: ["error": error ?? [:]])) ?? Data()
            throw ClaudeBackstory.error(status: 0, body: body)
        default:
            return []
        }
    }

    /// Checks how the reply ended. A paused turn (searching ran long) isn't continued: the
    /// notes stop with what's come, which is something unless nothing was written yet.
    func finish() throws {
        switch stopReason {
        case "refusal": throw BackstoryError.declined
        case "pause_turn" where !wroteText: throw BackstoryError.unavailable("The search took too long. Try again.")
        default: break
        }
    }

    private mutating func text(_ text: String?) -> [BackstoryUpdate] {
        guard let text, !text.isEmpty else { return [] }
        wroteText = true
        return [.text(text)]
    }

    static func source(_ citation: [String: Any]) -> BackstorySource? {
        guard let address = citation["url"] as? String, let url = URL(string: address) else { return nil }
        let title = (citation["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? address
        return BackstorySource(title: title, url: url, quote: citation["cited_text"] as? String)
    }
}
