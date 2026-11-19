import BitampPakKit
import CoreGraphics
import Foundation

/// The Deconstructor Pak: shows how the song that's playing was made, from MusicBrainz's open
/// data: what it samples, what has sampled it, whether it's a cover, its remixes and other
/// versions, and who wrote, produced and mixed it. No key and no model. A companion Pak,
/// like Backstory: it has no music of its own, and its cartridge opens its window.
///
/// A lookup sends the title, artist and album to MusicBrainz, so it waits for the user to ask
/// until they choose "Every track".
@MainActor
public final class DeconstructorPak: NotesPak {
    static let pakID = "deconstructor"
    public let id = DeconstructorPak.pakID
    public let name = "Deconstructor"
    public let schemes: Set<String> = []
    public let isAvailable = true
    public var isMusicSource: Bool { false }

    /// Who answers, for the window's words.
    static let serviceName = "MusicBrainz"

    private let service: BackstoryService
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    public convenience init(service: BackstoryService) {
        self.init(service: service, defaults: .standard)
    }

    init(service: BackstoryService, defaults: UserDefaults) {
        self.service = service
        self.defaults = defaults
    }

    private static let lookupKey = "pak.deconstructor.lookup"
    private static let prefetchKey = "pak.deconstructor.prefetch"

    /// "When I ask" until the user picks, since a lookup sends the song's tags out.
    var lookup: NotesLookup {
        get { defaults.string(forKey: Self.lookupKey).flatMap(NotesLookup.init) ?? .whenAsked }
        set { defaults.set(newValue.rawValue, forKey: Self.lookupKey); onChange?() }
    }

    /// Off until asked for: MusicBrainz allows a request a second, and a skipped song still spends them.
    var prefetch: Bool {
        get { defaults.bool(forKey: Self.prefetchKey) }
        set { defaults.set(newValue, forKey: Self.prefetchKey); onChange?() }
    }

    /// Notes are saved under this, with a version so a change to what's shown doesn't leave
    /// stale notes behind.
    var identity: String { "deconstructor/1" }

    func choice() -> NotesChoice? {
        NotesChoice(service: service, identity: identity, onDevice: false)
    }

    func onDeviceChoice() -> NotesChoice? { nil }

    public var account: PakAccount { .connected(name: Self.serviceName) }
    public func connect() async throws {}
    public func disconnect() {}
    public func search(_ term: String) async throws -> [PakTrack] { [] }
    public func metadata(for url: URL) async -> PakTrack? { nil }
    public func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}
