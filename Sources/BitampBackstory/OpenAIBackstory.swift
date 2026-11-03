import BitampPakKit
import Foundation

/// Notes from OpenAI's Responses API with its web search tool, streamed, with the user's
/// own key. Reasoning is kept low and searches few: at OpenAI's defaults a song took 30–40 s
/// in the spike, and with these settings about 9 s.
public struct OpenAIBackstory: BackstoryService {
    public enum Model: String, CaseIterable, Sendable {
        /// The default: about 2¢ a song in the spike.
        case mini = "gpt-5-mini"
        /// Richer notes, for several times the price.
        case full = "gpt-5.5"
    }

    let key: String
    let model: Model
    let session: URLSession

    public init(key: String, model: Model = .mini, session: URLSession = .shared) {
        self.key = key
        self.model = model
        self.session = session
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Claude's instructions, and a request for citations: at low effort, OpenAI's models
    /// searched but often cited nothing without it.
    static let instructions = ClaudeBackstory.system + "\n\nCite the web pages each fact comes from."

    static func body(for track: PakNowPlaying, model: Model) -> [String: Any] {
        [
            "model": model.rawValue,
            "max_output_tokens": 4000,
            "stream": true,
            "instructions": instructions,
            "input": ClaudeBackstory.prompt(for: track),
            "reasoning": ["effort": "low"],
            "tools": [["type": "web_search", "search_context_size": "low"]],
            "max_tool_calls": 2,
        ]
    }

    func request(for track: PakNowPlaying) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
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
                    var stream = OpenAIStream()
                    for try await line in bytes.lines {
                        for update in try stream.feed(line) { continuation.yield(update) }
                    }
                    for update in try stream.finish() { continuation.yield(update) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as BackstoryError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where ClaudeBackstory.offlineCodes.contains(error.code) {
                    continuation.finish(throwing: BackstoryError.offline("Couldn't reach OpenAI: \(error.localizedDescription)"))
                } catch {
                    continuation.finish(throwing: BackstoryError.failed("Couldn't reach OpenAI: \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What an unsuccessful reply means.
    static func error(status: Int, body: Data) -> BackstoryError {
        let details = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        return error(status: status, code: details?["code"] as? String, message: details?["message"] as? String)
    }

    static func error(status: Int, code: String?, message: String?) -> BackstoryError {
        switch (status, code) {
        case (401, _), (_, "invalid_api_key"):
            return .badKey
        case (_, "insufficient_quota"):
            return .limited("The OpenAI account is out of credit.")
        case (429, _), (_, "rate_limit_exceeded"):
            return .limited("OpenAI says there have been too many requests. Try again in a minute.")
        case (500..., _), (_, "server_error"):
            return .unavailable("OpenAI is busy right now. Try again in a moment.")
        default:
            return .failed(message.map { "OpenAI: \($0)" } ?? "OpenAI answered with an error (\(status)).")
        }
    }
}

/// Reads the Responses API's server-sent events. OpenAI writes each citation into the text
/// as a link, "([site](https://…))", in pieces, and then names it in an annotation event; the
/// links are taken out, and each one's annotation becomes a citation of the words before it.
struct OpenAIStream {
    /// Text held back because it may be the start of a link.
    private var pending = ""
    /// Words after a link, held until its annotation names it, so the mark goes where the
    /// link was.
    private var held = ""
    /// A link taken out of the text whose annotation hasn't come yet.
    private var awaiting: BackstorySource?
    private var wroteText = false

    mutating func feed(_ line: String) throws -> [BackstoryUpdate] {
        guard line.hasPrefix("data:"),
              let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
        else { return [] }
        switch event["type"] as? String {
        case "response.output_text.delta":
            return text(event["delta"] as? String ?? "")
        case "response.output_text.annotation.added":
            guard let annotation = event["annotation"] as? [String: Any], annotation["type"] as? String == "url_citation",
                  let address = annotation["url"] as? String, let url = Self.clean(address) else { return [] }
            let title = (annotation["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? address
            guard awaiting != nil else { return [.cite([BackstorySource(title: title, url: url)])] }
            awaiting = nil
            return [.cite([BackstorySource(title: title, url: url)])] + release()
        case "response.incomplete":
            let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
            if reason == "content_filter" { throw BackstoryError.declined }
            return []
        case "response.failed":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
            throw OpenAIBackstory.error(status: 0, code: error?["code"] as? String, message: error?["message"] as? String)
        case "error":
            throw OpenAIBackstory.error(status: 0, code: event["code"] as? String, message: event["message"] as? String)
        default:
            return []
        }
    }

    /// Whatever is still held, once the reply has ended.
    mutating func finish() throws -> [BackstoryUpdate] {
        var updates: [BackstoryUpdate] = []
        if let awaiting {
            updates.append(.cite([awaiting]))
            self.awaiting = nil
        }
        let rest = held + pending
        held = ""
        pending = ""
        if !rest.isEmpty { updates.append(.text(rest)) }
        if !wroteText && updates.isEmpty { throw BackstoryError.failed("No notes came back. Try again.") }
        return updates
    }

    private mutating func text(_ delta: String) -> [BackstoryUpdate] {
        pending += delta
        var out = ""
        var updates: [BackstoryUpdate] = []
        while !pending.isEmpty {
            guard let start = pending.firstIndex(where: { $0 == "(" || $0 == "[" }) else {
                out += pending
                pending = ""
                break
            }
            out += pending[..<start]
            pending = String(pending[start...])
            switch Self.link(at: pending) {
            case .incomplete:
                return emit(out, updates)
            case .none:
                out.append(pending.removeFirst())
            case .link(let length, let label, let url):
                pending.removeFirst(length)
                // A link's own space goes with it.
                while out.last == " " { out.removeLast() }
                // An earlier link never named: its citation, then the words after it.
                if let earlier = awaiting {
                    awaiting = nil
                    updates.append(.cite([earlier]))
                    updates += release()
                }
                updates += emit(out, [])
                out = ""
                awaiting = BackstorySource(title: label, url: url)
            }
        }
        return emit(out, updates)
    }

    /// Passes `words` on, or holds them while a link waits for its annotation.
    private mutating func emit(_ words: String, _ updates: [BackstoryUpdate]) -> [BackstoryUpdate] {
        guard !words.isEmpty else { return updates }
        if awaiting != nil {
            held += words
            return updates
        }
        wroteText = true
        return updates + [.text(words)]
    }

    /// The words held after a link, now that its citation is out.
    private mutating func release() -> [BackstoryUpdate] {
        let words = held
        held = ""
        guard !words.isEmpty else { return [] }
        wroteText = true
        return [.text(words)]
    }

    enum Link: Equatable {
        case link(length: Int, label: String, url: URL)
        /// Could still become a link; wait for more.
        case incomplete
        case none
    }

    /// Whether `text` starts with a markdown link, "[label](https://…)", optionally in
    /// parentheses.
    static func link(at text: String) -> Link {
        let characters = Array(text)
        var i = 0
        let wrapped = characters.first == "("
        if wrapped { i += 1 }
        guard i < characters.count else { return .incomplete }
        guard characters[i] == "[" else { return .none }
        i += 1
        var label = ""
        while i < characters.count, characters[i] != "]" {
            if characters[i] == "\n" || label.count > 200 { return .none }
            label.append(characters[i])
            i += 1
        }
        guard i < characters.count else { return .incomplete }
        i += 1  // "]"
        guard i < characters.count else { return .incomplete }
        guard characters[i] == "(" else { return .none }
        i += 1
        var address = ""
        while i < characters.count, characters[i] != ")" {
            if characters[i] == " " || characters[i] == "\n" || address.count > 2000 { return .none }
            address.append(characters[i])
            i += 1
        }
        guard i < characters.count else {
            // Unfinished: wait if it's still on its way to being a web address.
            return address.hasPrefix("http") || "http".hasPrefix(address) ? .incomplete : .none
        }
        i += 1  // ")"
        if wrapped {
            guard i < characters.count else { return .incomplete }
            guard characters[i] == ")" else { return .none }
            i += 1
        }
        guard address.hasPrefix("http"), let url = clean(address) else { return .none }
        return .link(length: i, label: label, url: url)
    }

    /// The address without the "utm_source=openai" OpenAI adds.
    static func clean(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address) else { return URL(string: address) }
        parts.queryItems = parts.queryItems?.filter { $0.name != "utm_source" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.url
    }
}
