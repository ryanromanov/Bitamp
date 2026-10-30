import Foundation

/// What a backstory service is told about the song that's playing: its tags, never its
/// audio or its file's name.
public struct PakNowPlaying: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String?
    public var album: String?

    public init(title: String, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// A web page the notes draw on.
public struct BackstorySource: Sendable, Hashable, Codable {
    public var title: String
    public var url: URL
    /// The words on the page the notes rest on, when the service says.
    public var quote: String?

    public init(title: String, url: URL, quote: String? = nil) {
        self.title = title
        self.url = url
        self.quote = quote
    }
}

/// A piece of the notes as they arrive.
public enum BackstoryUpdate: Sendable, Equatable {
    /// More words, to add to what's come so far.
    case text(String)
    /// The sources behind the words that came just before.
    case cite([BackstorySource])
}

/// Something that writes notes about a song, such as Claude or OpenAI with web search.
public protocol BackstoryService: Sendable {
    /// The notes, a piece at a time. Ends early with an error if the service fails.
    func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error>
}

/// Why a service couldn't write notes, in words for the panel.
public enum BackstoryError: Error, Equatable, LocalizedError {
    /// The key is missing, wrong or revoked.
    case badKey
    /// Too many requests, or the account is out of credit.
    case limited(String)
    /// The service is busy or down; trying later may work.
    case unavailable(String)
    /// The service couldn't be reached: no network, or it timed out.
    case offline(String)
    /// The service wouldn't answer this one.
    case declined
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .badKey: "The API key wasn't accepted. Check it in the setup."
        case .limited(let message), .unavailable(let message), .offline(let message), .failed(let message): message
        case .declined: "The service declined to write about this song."
        }
    }
}
