import Foundation

public enum PlaybackState: Sendable {
    case stopped, playing, paused
}

/// What Bitamp can do to a backend's audio. Bitamp's own engine does everything; a backend
/// that plays copy-protected audio itself (a streaming service's own player) does none of it.
public struct PlaybackCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let equalizer = PlaybackCapabilities(rawValue: 1 << 0)
    public static let visualizer = PlaybackCapabilities(rawValue: 1 << 1)
    public static let retroSound = PlaybackCapabilities(rawValue: 1 << 2)
    /// Bitamp's volume and balance sliders.
    public static let volume = PlaybackCapabilities(rawValue: 1 << 3)
    public static let all: PlaybackCapabilities = [.equalizer, .visualizer, .retroSound, .volume]
}

/// The loaded track as the main window shows it. Any field after the duration can be
/// missing when the backend doesn't know it.
public struct NowPlaying: Sendable, Equatable {
    /// The queue item's URL: a file, or a Pak's own scheme.
    public let url: URL
    public var title: String
    public var artist: String?
    public let duration: Double
    public var sampleRate: Double?
    public var channels: Int?
    public var kbps: Int?

    public init(
        url: URL, title: String, artist: String? = nil, duration: Double,
        sampleRate: Double? = nil, channels: Int? = nil, kbps: Int? = nil
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.kbps = kbps
    }
}

/// Something that plays one queue item at a time: Bitamp's own engine, or a Pak that
/// plays audio itself.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var state: PlaybackState { get }
    var nowPlaying: NowPlaying? { get }
    /// Seconds into the loaded track.
    var currentTime: Double { get }
    var capabilities: PlaybackCapabilities { get }
    /// Called after a track plays to the end and the backend has stopped.
    var onTrackEnd: (() -> Void)? { get set }
    /// Called when the loaded track turns out not to play after `load` returned, for a
    /// backend that finds out later (a song that has to be looked up first, say).
    var onLoadFailure: ((Error) -> Void)? { get set }

    /// Loads `url` stopped, ready to play. Throws if it can't be played.
    func load(_ url: URL) throws
    /// Resumes when paused; otherwise starts the track from the top.
    func play()
    /// Toggles between playing and paused.
    func pause()
    func stop()
    func seek(to seconds: Double)
}
