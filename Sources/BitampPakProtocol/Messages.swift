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
    /// The newest version Bitamp speaks. A Pak declares the one it needs; Bitamp runs any
    /// up to this, and an older Bitamp won't install a Pak that needs a newer one.
    /// 1: music Paks (search, track, resolve, browse). 2: also `notes` companions, which
    /// an older Bitamp would otherwise show as an empty music cartridge.
    public static let version = 2
    /// The version a Pak with the `notes` capability declares.
    public static let notesVersion = 2
    /// The manifest's `capabilities` Bitamp knows. `browse`: the Media Library asks the Pak
    /// what's in it. `notes`: a companion Pak, with no music of its own, that writes about
    /// the song that's playing, in a window of its own.
    public static let browse = "browse"
    public static let notes = "notes"
    public static let knownCapabilities: Set<String> = [browse, notes]
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
    /// What the Pak does beyond search, such as `"browse"`. In the manifest rather than the
    /// `hello` reply, because Bitamp needs to know before it starts the Pak. Bitamp versions
    /// that don't know a capability ignore it, so a Pak that browses still searches there.
    public var capabilities: [String]?

    public init(id: String, name: String, version: String, executable: String,
                protocol: Int = PakProtocol.version, description: String? = nil, settings: [PakSettingDefinition]? = nil,
                capabilities: [String]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.executable = executable
        self.protocol = `protocol`
        self.description = description
        self.settings = settings
        self.capabilities = capabilities
    }

    /// Whether the manifest lists `capability`.
    public func can(_ capability: String) -> Bool {
        capabilities?.contains(capability) == true
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
    /// The track's cover, for the Media Library.
    public var artwork: PakArtworkInfo?

    public init(id: String, title: String, artist: String? = nil, album: String? = nil, duration: Double? = nil,
                artwork: PakArtworkInfo? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
    }
}

/// A picture: a file the Pak made or downloaded, or a URL Bitamp fetches, with headers
/// for servers that need them. Shaped like `PakSource`.
public struct PakArtworkInfo: Codable, Equatable, Hashable, Sendable {
    public var file: String?
    public var url: String?
    public var headers: [String: String]?

    public init(file: String? = nil, url: String? = nil, headers: [String: String]? = nil) {
        self.file = file
        self.url = url
        self.headers = headers
    }

    public static func file(_ url: URL) -> PakArtworkInfo { PakArtworkInfo(file: url.path) }
    public static func url(_ url: URL, headers: [String: String]? = nil) -> PakArtworkInfo {
        PakArtworkInfo(url: url.absoluteString, headers: headers)
    }
}

// MARK: - Browsing

/// Where to look, for `browse`:
///
///     {"kind":"root"}                      the sidebar
///     {"kind":"place","id":"albums"}       a place the Pak listed
///     {"kind":"search","term":"ode"}       the Media Library's search
public enum PakBrowseLocation: Codable, Equatable, Hashable, Sendable {
    case root
    case place(String)
    case search(String)

    private enum Keys: String, CodingKey { case kind, id, term }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "root": self = .root
        case "place": self = .place(try container.decode(String.self, forKey: .id))
        case "search": self = .search(try container.decodeIfPresent(String.self, forKey: .term) ?? "")
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown location \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .root:
            try container.encode("root", forKey: .kind)
        case .place(let id):
            try container.encode("place", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .search(let term):
            try container.encode("search", forKey: .kind)
            try container.encode(term, forKey: .term)
        }
    }
}

/// What's at a location: an optional header (for an album or playlist), shelves of tracks
/// and places, and a cursor when there's more of the last shelf.
public struct PakBrowsePage: Codable, Equatable, Sendable {
    public var header: PakHeaderInfo?
    public var shelves: [PakShelfInfo]
    /// Sent back with the same location for the next page.
    public var cursor: String?

    public init(header: PakHeaderInfo? = nil, shelves: [PakShelfInfo] = [], cursor: String? = nil) {
        self.header = header
        self.shelves = shelves
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(PakHeaderInfo.self, forKey: .header)
        shelves = try container.decodeIfPresent([PakShelfInfo].self, forKey: .shelves) ?? []
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
    }
}

/// The top of an album or playlist page.
public struct PakHeaderInfo: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    /// "Electronic · 2025 · 10 songs".
    public var detail: String?
    public var artwork: PakArtworkInfo?

    public init(title: String, subtitle: String? = nil, detail: String? = nil, artwork: PakArtworkInfo? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.artwork = artwork
    }
}

/// A row of a page, such as "Albums". One shelf without a title is a plain list.
public struct PakShelfInfo: Codable, Equatable, Sendable {
    public var title: String?
    public var items: [PakItemInfo]

    public init(title: String? = nil, items: [PakItemInfo]) {
        self.title = title
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case title, items }

    /// Items of a type this version doesn't know are left out, rather than failing the page.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let items = try container.decodeIfPresent([Lenient<PakItemInfo>].self, forKey: .items) ?? []
        self.items = items.compactMap(\.value)
    }
}

/// One thing on a shelf: `{"track":{…}}` or `{"place":{…}}`.
public enum PakItemInfo: Codable, Equatable, Sendable {
    case track(PakTrackInfo)
    case place(PakPlaceInfo)

    private enum Keys: String, CodingKey { case track, place }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let track = try container.decodeIfPresent(PakTrackInfo.self, forKey: .track) {
            self = .track(track)
        } else if let place = try container.decodeIfPresent(PakPlaceInfo.self, forKey: .place) {
            self = .place(place)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An item is a track or a place"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .track(let track): try container.encode(track, forKey: .track)
        case .place(let place): try container.encode(place, forKey: .place)
        }
    }
}

/// Something to open: a section of the sidebar, an album, an artist or a playlist.
public struct PakPlaceInfo: Codable, Equatable, Sendable {
    /// `section`, `album`, `artist` or `playlist`. Bitamp shows a kind it doesn't know as a section.
    public var kind: String
    /// The Pak's own, sent back as `{"kind":"place","id":…}`.
    public var id: String
    public var title: String
    /// An album's artist, a playlist's curator.
    public var subtitle: String?
    public var artwork: PakArtworkInfo?

    public static let kinds: Set<String> = ["section", "album", "artist", "playlist"]

    public init(kind: String, id: String, title: String, subtitle: String? = nil, artwork: PakArtworkInfo? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
    }
}

/// Decodes a value, or nil if it doesn't decode, so one odd item doesn't sink a list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Notes

/// The song that's playing, for `notes`: its tags, never its audio or its file's name.
/// More fields may come; ignore any you don't know.
public struct PakSongInfo: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?

    public init(title: String, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// A web page the notes rest on. Bitamp numbers them, and marks the words before each
/// citation with its number.
public struct PakCitation: Codable, Equatable, Hashable, Sendable {
    public var title: String
    /// An http or https address; Bitamp drops a citation with any other.
    public var url: String
    /// The words on the page the notes rest on.
    public var quote: String?

    public init(title: String, url: String, quote: String? = nil) {
        self.title = title
        self.url = url
        self.quote = quote
    }
}

/// Part of the notes, sent before the answer to `notes` as `{"id":7,"update":{…}}`:
/// more words (`text`), or the sources of the words just sent (`cite`).
public struct PakNotesUpdate: Codable, Equatable, Sendable {
    public var text: String?
    public var cite: [PakCitation]?

    public init(text: String? = nil, cite: [PakCitation]? = nil) {
        self.text = text
        self.cite = cite
    }

    public static func text(_ text: String) -> PakNotesUpdate { PakNotesUpdate(text: text) }
    public static func cite(_ citations: [PakCitation]) -> PakNotesUpdate { PakNotesUpdate(cite: citations) }
}

/// A line from the Pak that's part of an answer still to come.
public struct PakUpdate<Update: Codable>: Codable {
    public var id: Int
    public var update: Update
    public init(id: Int, update: Update) {
        self.id = id
        self.update = update
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

    /// Asks what's at a location (`browse`), or for more of it after `cursor`. Sent only to
    /// Paks whose manifest lists the `browse` capability.
    public struct Browse: Codable, Sendable {
        public var location: PakBrowseLocation
        public var cursor: String?
        public init(location: PakBrowseLocation, cursor: String? = nil) {
            self.location = location
            self.cursor = cursor
        }
    }

    public struct BrowseResult: Codable, Sendable {
        public var page: PakBrowsePage
        public init(page: PakBrowsePage) { self.page = page }
    }

    /// Asks for notes about the song that's playing. Sent only to Paks whose manifest lists
    /// the `notes` capability. The Pak may send `update` lines first, then answers; whatever
    /// the answer holds is added after them.
    public struct Notes: Codable, Sendable {
        public var song: PakSongInfo
        public init(song: PakSongInfo) { self.song = song }
    }

    public struct NotesResult: Codable, Sendable {
        /// More words, after any sent as updates. A Pak that doesn't stream puts all of them here.
        public var text: String?
        /// The sources of `text`.
        public var sources: [PakCitation]?
        public init(text: String? = nil, sources: [PakCitation]? = nil) {
            self.text = text
            self.sources = sources
        }
    }

    /// Bitamp no longer wants the answer to request `id`, such as notes for a song that was
    /// skipped. Not answered. The Pak should stop working on it; any later lines for it are ignored.
    public struct Cancel: Codable, Sendable {
        public var id: Int
        public init(id: Int) { self.id = id }
    }

    public struct Empty: Codable, Sendable {
        public init() {}
    }

    public static let hello = "hello"
    public static let configure = "configure"
    public static let search = "search"
    public static let track = "track"
    public static let resolve = "resolve"
    public static let browse = "browse"
    public static let notes = "notes"
    public static let cancel = "cancel"
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
