import Foundation

/// What Bitamp and a third-party Pak say to each other. A Pak is a program Bitamp starts;
/// they talk in JSON, one object per line: Bitamp writes requests to the Pak's standard
/// input, the Pak writes one response per request to its standard output. Anything the
/// Pak prints to standard error goes to Bitamp's log. See docs/PAK-SDK.md.
///
///     → {"id":1,"method":"search","params":{"term":"ode"}}
///     ← {"id":1,"result":{"tracks":[{"id":"ode-to-joy","title":"Ode to Joy","artist":"Beethoven"}]}}
///     ← {"id":2,"error":{"message":"No such track"}}
public enum PakProtocol {
    /// Bumped when a change would break existing Paks.
    public static let version = 1
    /// The manifest inside every `.bitpak` folder.
    public static let manifestName = "pak.json"
}

/// The `.bitpak` folder's `pak.json`.
public struct PakManifest: Codable, Equatable, Sendable {
    /// Lowercase letters, digits and hyphens. Names the Pak's settings and its tracks' URLs.
    public var id: String
    /// "Demo"; Bitamp shows "Demo Pak".
    public var name: String
    public var version: String
    /// The program to run, relative to the `.bitpak` folder.
    public var executable: String
    /// The protocol version the Pak speaks.
    public var `protocol`: Int
    public var description: String?
    public var settings: [PakSettingDefinition]?

    public init(id: String, name: String, version: String, executable: String,
                protocol: Int = PakProtocol.version, description: String? = nil, settings: [PakSettingDefinition]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.executable = executable
        self.protocol = `protocol`
        self.description = description
        self.settings = settings
    }

    /// Whether `id` is usable: 1–32 lowercase letters, digits and hyphens, starting with a letter.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.first, first.isASCII, first.isLowercase, id.count <= 32 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

/// A setting the user fills in, such as a server address or a password.
public struct PakSettingDefinition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// One line of text.
        case text
        /// Text kept in the Keychain and never shown.
        case password
        /// One of `options`.
        case choice
    }

    public var key: String
    public var label: String
    public var kind: Kind
    public var options: [String]?
    public var defaultValue: String?

    public init(key: String, label: String, kind: Kind, options: [String]? = nil, defaultValue: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.options = options
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey {
        case key, label, kind = "type", options, defaultValue = "default"
    }
}

/// One track, as a Pak describes it. `id` is the Pak's own; Bitamp never looks inside it.
public struct PakTrackInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double?

    public init(id: String, title: String, artist: String? = nil, album: String? = nil, duration: Double? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Whether the Pak can play right now.
public struct PakAccountState: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Ready.
        case connected
        /// Needs settings filled in or a sign-in.
        case disconnected
        /// Working, with a catch the message explains.
        case limited
    }

    public var state: State
    public var message: String?

    public init(_ state: State, message: String? = nil) {
        self.state = state
        self.message = message
    }

    public static let connected = PakAccountState(.connected)
}

/// Where a track's audio is: a file the Pak made or downloaded, or a URL Bitamp downloads.
public struct PakSource: Codable, Equatable, Sendable {
    public var file: String?
    public var url: String?
    /// HTTP headers for `url`, such as an authorization token.
    public var headers: [String: String]?

    public init(file: String? = nil, url: String? = nil, headers: [String: String]? = nil) {
        self.file = file
        self.url = url
        self.headers = headers
    }

    public static func file(_ url: URL) -> PakSource { PakSource(file: url.path) }
    public static func url(_ url: URL, headers: [String: String]? = nil) -> PakSource {
        PakSource(url: url.absoluteString, headers: headers)
    }
}

// MARK: - Requests and responses

/// Each method's parameters and result.
public enum PakMethod {
    /// First, once per launch: the protocol version, the user's settings, and a folder the
    /// Pak may keep files in. The Pak answers with its account state.
    public struct Hello: Codable, Sendable {
        public var `protocol`: Int
        public var settings: [String: String]
        public var cacheDirectory: String
        public init(protocol: Int, settings: [String: String], cacheDirectory: String) {
            self.protocol = `protocol`
            self.settings = settings
            self.cacheDirectory = cacheDirectory
        }
    }

    /// The user changed the settings.
    public struct Configure: Codable, Sendable {
        public var settings: [String: String]
        public init(settings: [String: String]) { self.settings = settings }
    }

    public struct AccountResult: Codable, Sendable {
        public var account: PakAccountState
        public init(account: PakAccountState) { self.account = account }
    }

    public struct Search: Codable, Sendable {
        public var term: String
        public init(term: String) { self.term = term }
    }

    public struct SearchResult: Codable, Sendable {
        public var tracks: [PakTrackInfo]
        public init(tracks: [PakTrackInfo]) { self.tracks = tracks }
    }

    /// Asks about one track (`track`), or where its audio is (`resolve`).
    public struct TrackID: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    public struct TrackResult: Codable, Sendable {
        public var track: PakTrackInfo?
        public init(track: PakTrackInfo?) { self.track = track }
    }

    public struct ResolveResult: Codable, Sendable {
        public var source: PakSource
        public init(source: PakSource) { self.source = source }
    }

    public struct Empty: Codable, Sendable {
        public init() {}
    }

    public static let hello = "hello"
    public static let configure = "configure"
    public static let search = "search"
    public static let track = "track"
    public static let resolve = "resolve"
    /// Bitamp is quitting or removing the Pak; it should exit after answering.
    public static let shutdown = "shutdown"
}

/// One line from Bitamp.
public struct PakRequest<Params: Codable>: Codable {
    public var id: Int
    public var method: String
    public var params: Params
    public init(id: Int, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Just the id and method, to decide how to decode the rest.
public struct PakRequestHeader: Codable {
    public var id: Int
    public var method: String
}

public struct PakError: Codable, Error, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// One line from the Pak.
public struct PakResponse<Result: Codable>: Codable {
    public var id: Int
    public var result: Result?
    public var error: PakError?
    public init(id: Int, result: Result? = nil, error: PakError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}
