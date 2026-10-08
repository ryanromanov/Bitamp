import BitampPakKit
import Foundation
import MusicKit

/// Plays one Apple Music song at a time through `ApplicationMusicPlayer`, with Bitamp's
/// queue deciding what comes next.
///
/// MusicKit is asynchronous and doesn't announce the end of a song, so `state` is what
/// Bitamp asked for, and a timer watches the player: for the song ending, and for
/// pauses from elsewhere (media keys, Control Center).
@available(macOS 14, *)
@MainActor
final class AppleMusicBackend: PlaybackBackend {
    private(set) var state = PlaybackState.stopped
    private(set) var nowPlaying: NowPlaying?
    let capabilities: PlaybackCapabilities = []
    var onTrackEnd: (() -> Void)?
    var onLoadFailure: ((Error) -> Void)?

    private let songs: SongStore
    private var player: ApplicationMusicPlayer { .shared }
    private var reference: AppleMusicURL?
    private var song: Song?
    /// True once the player has the song queued and was told to play it.
    private var started = false
    /// True while the song is being queued, so two quick plays don't queue it twice.
    private var starting = false
    /// Where to start, for a seek made before the song had started.
    private var startTime: Double = 0
    /// Bumped on every load, so MusicKit's late answers about an earlier song are ignored.
    private var generation = 0
    private var watcher: Timer?
    /// The furthest the player got, and how many checks in a row it wasn't playing.
    private var lastPlayingTime: Double = 0
    private var idleChecks = 0

    init(songs: SongStore) {
        self.songs = songs
    }

    var currentTime: Double {
        switch state {
        case .stopped: return 0
        case .playing, .paused: return started ? player.playbackTime : startTime
        }
    }

    func load(_ url: URL) throws {
        guard let reference = AppleMusicURL(url) else { throw AppleMusicError.notASong(url) }
        stop()
        generation += 1
        self.reference = reference
        song = songs.cached(reference)
        nowPlaying = song.map { Self.nowPlaying($0, url: url) }
            ?? NowPlaying(url: url, title: "Apple Music", duration: 0)
        guard song == nil else { return }
        let generation = generation
        Task {
            do {
                let song = try await songs.song(for: reference)
                guard generation == self.generation else { return }
                self.song = song
                nowPlaying = Self.nowPlaying(song, url: url)
                if state == .playing { await start(generation) }
            } catch {
                fail(error, generation)
            }
        }
    }

    /// Resumes when paused; otherwise starts the song from the top.
    func play() {
        guard reference != nil else { return }
        if state == .paused {
            resume()
            return
        }
        stop()
        state = .playing
        let generation = generation
        if song != nil { Task { await start(generation) } }
        // Otherwise the lookup `load` started plays it when it arrives.
    }

    func pause() {
        switch state {
        case .playing:
            state = .paused
            if started { player.pause() }
        case .paused:
            resume()
        case .stopped:
            break
        }
    }

    func stop() {
        if started { player.stop() }
        started = false
        startTime = 0
        state = .stopped
        stopWatching()
    }

    func seek(to seconds: Double) {
        guard state != .stopped else { return }
        let seconds = min(max(0, seconds), nowPlaying?.duration ?? seconds)
        if started {
            player.playbackTime = seconds
            lastPlayingTime = seconds
        } else {
            startTime = seconds
        }
    }

    private func resume() {
        state = .playing
        guard started else {
            let generation = generation
            if song != nil { Task { await start(generation) } }
            return
        }
        let generation = generation
        Task {
            do {
                try await player.play()
            } catch {
                fail(error, generation)
            }
        }
        watch()
    }

    /// Queues the song in MusicKit's player and starts it, unless something else has
    /// been asked for since.
    private func start(_ generation: Int) async {
        guard generation == self.generation, let song, !started, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            player.queue = [song]
            try await player.prepareToPlay()
            guard generation == self.generation, state != .stopped else { return }
            if startTime > 0 { player.playbackTime = startTime }
            started = true
            lastPlayingTime = startTime
            if state == .playing {
                try await player.play()
                watch()
            }
        } catch {
            fail(error, generation)
        }
    }

    /// Reports a song that won't play, if it's still the one loaded and still wanted;
    /// a song that fails while stopped just stays stopped.
    private func fail(_ error: Error, _ generation: Int) {
        guard generation == self.generation else { return }
        let wanted = state != .stopped
        stop()
        if wanted { onLoadFailure?(error) }
    }

    // MARK: - Watching the player

    private func watch() {
        guard watcher == nil else { return }
        idleChecks = 0
        watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    private func check() {
        guard started, state == .playing else { return }
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward:
            idleChecks = 0
            lastPlayingTime = player.playbackTime
        case .paused, .stopped, .interrupted:
            // Give MusicKit half a second to settle after play() before deciding anything.
            idleChecks += 1
            guard idleChecks >= 2 else { return }
            let duration = nowPlaying?.duration ?? 0
            if player.queue.currentEntry == nil || duration > 0 && lastPlayingTime >= duration - 1.5 {
                stop()
                onTrackEnd?()
            } else if player.state.playbackStatus == .paused {
                // Paused from outside Bitamp.
                state = .paused
                stopWatching()
            }
        @unknown default:
            break
        }
    }

    private static func nowPlaying(_ song: Song, url: URL) -> NowPlaying {
        NowPlaying(url: url, title: song.title, artist: song.artistName, duration: SongStore.duration(of: song) ?? 0)
    }
}
