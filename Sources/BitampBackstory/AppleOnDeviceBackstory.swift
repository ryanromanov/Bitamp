import BitampPakKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, from macOS 26 on Macs with Apple Intelligence: free, private
/// and offline, but with no web search, so it knows less and cites nothing. Backstory uses
/// it when chosen, when there's no key for the cloud service, and when that can't be reached.
public enum AppleOnDevice {
    /// Whether this macOS has the model at all (macOS 26 or later). It may still be
    /// unavailable on this Mac; see `isAvailable`.
    public static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// Whether the model can answer now. It isn't on older macOS, on Macs without Apple
    /// Intelligence or with it off, or while the model downloads.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// The service, or nil where the model can't run. With `wikipedia`, it looks the song up
    /// there first and writes from the article.
    public static func service(wikipedia: WikipediaFacts? = nil) -> BackstoryService? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable { return OnDeviceBackstory(wikipedia: wikipedia) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
struct OnDeviceBackstory: BackstoryService {
    let wikipedia: WikipediaFacts?

    static let instructions = """
    You write a few sentences about the song a person is listening to in a music player: \
    when it came out, what album it's from, or what it's about. Write one short paragraph of \
    at most 70 words, in plain text with no markdown.

    Only say what you're sure of about this exact recording. If you don't know it, say in \
    one sentence that you don't know this song, and stop. Never guess, and never describe a \
    different song.
    """

    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Without an article, as when nothing is found or Wikipedia can't be
                    // reached, the model writes from memory.
                    let article = await wikipedia?.article(for: track, characters: Self.articleBudget(for: track))
                    try Task.checkCancellation()
                    let session = LanguageModelSession(instructions: article == nil ? Self.instructions : WikipediaPrompt.instructions)
                    let prompt = article.map { WikipediaPrompt.prompt(for: track, article: $0) } ?? ClaudeBackstory.prompt(for: track)
                    // Each snapshot is the whole answer so far; pass on what's new.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let text = snapshot.content
                        if text.hasPrefix(sent), text.count > sent.count {
                            continuation.yield(.text(String(text.dropFirst(sent.count))))
                        }
                        sent = text
                    }
                    if let article, !sent.isEmpty {
                        continuation.yield(.cite([BackstorySource(title: WikipediaPrompt.sourceTitle(article), url: article.url)]))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.error(error))
                } catch {
                    continuation.finish(throwing: BackstoryError.failed("The on-device model: \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How much article fits: the model's context less room for the instructions and the
    /// answer, at about three characters a token, or one for Chinese and Japanese.
    static func articleBudget(for track: PakNowPlaying) -> Int {
        let tokens = max(SystemLanguageModel.default.contextSize - 1200, 1000)
        let perToken = WikipediaFacts.languages(for: track).count > 1 ? 1 : 3
        return min(tokens * perToken, 9000)
    }

    static func error(_ error: LanguageModelSession.GenerationError) -> BackstoryError {
        switch error {
        case .guardrailViolation, .refusal: .declined
        case .assetsUnavailable: .unavailable("Apple's on-device model isn't ready yet. Try again later.")
        case .rateLimited, .concurrentRequests: .limited("The on-device model is busy. Try again in a moment.")
        case .unsupportedLanguageOrLocale: .failed("The on-device model doesn't support this language.")
        default: .failed("The on-device model couldn't answer: \(error.localizedDescription)")
        }
    }
}
#endif

/// What the on-device model is told when it writes from a Wikipedia article.
enum WikipediaPrompt {
    static let instructions = """
    You write a few sentences about the song a person is listening to in a music player, \
    using only the Wikipedia text you're given: how it was made, what it's about, how it did. \
    Write one or two short paragraphs, at most 90 words in all, in English, in plain text with \
    no markdown and no headings.

    Say only what the text says. Don't add anything from memory. If the text is about the \
    album or the artist rather than the song, say so in a few words, and don't present it as \
    being about the song.
    """

    static func prompt(for track: PakNowPlaying, article: WikipediaArticle) -> String {
        let about = switch article.kind {
        case .song: "the song"
        case .album: "the album \"\(article.title)\" (there's no article about the song itself)"
        case .artist: "the artist \(article.title) (there's no article about the song or its album)"
        }
        return ClaudeBackstory.prompt(for: track) + "\n\nWikipedia's article about \(about):\n\n" + article.text
    }

    /// The article's title; the window adds "en.wikipedia.org".
    static func sourceTitle(_ article: WikipediaArticle) -> String {
        article.title
    }
}
