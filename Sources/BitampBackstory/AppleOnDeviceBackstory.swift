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

    /// The service, or nil where the model can't run.
    public static func service() -> BackstoryService? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable { return OnDeviceBackstory() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
struct OnDeviceBackstory: BackstoryService {
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
                    let session = LanguageModelSession(instructions: Self.instructions)
                    // Each snapshot is the whole answer so far; pass on what's new.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: ClaudeBackstory.prompt(for: track)) {
                        let text = snapshot.content
                        if text.hasPrefix(sent), text.count > sent.count {
                            continuation.yield(.text(String(text.dropFirst(sent.count))))
                        }
                        sent = text
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
