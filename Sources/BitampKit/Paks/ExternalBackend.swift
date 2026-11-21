import BitampPakKit
import BitampPakProtocol
import Foundation

/// What `ExternalBackend` needs of a Pak that plays its own audio: to send it playback
/// commands, and to hear what its player does. `ExternalPak` is the real one; tests use a fake.
@MainActor
protocol PakPlaybackTransport: AnyObject {
    func load(trackID: String) async throws -> PakMethod.LoadResult
    /// `play`, `pause`, `resume` or `stop`.
    func command(_ method: String) async throws
    func seek(to seconds: Double) async throws
    /// The Pak's program, for the visualizer to listen to when the Pak says its sound is its own.
    var audioProcessID: Int32? { get }
    var onPlaybackEvent: ((PakPlaybackEvent) -> Void)? { get set }
    /// The program ended, so the player is gone with it.
    var onProgramExit: (() -> Void)? { get set }
}

/// Plays a `playback` Pak's tracks by telling the Pak what to do and following what its
/// player reports (see `PakPlaybackEvent`). Bitamp's equalizer and Retro Sound can't reach the
/// sound, so it has no capabilities, like Apple Music's.
///
/// `state` is what Bitamp asked for, and moves at once; the Pak's reports then correct it and
/// keep the clock. Commands go to the Pak one at a time in the order they were given, through a
/// single pump, because separate tasks could overtake each other. Each belongs to the track
/// that was loaded when it was given: a later `load` drops the ones still waiting and cancels
/// the one running, so a slow load doesn't hold up the next song.
@MainActor
final class ExternalBackend: PlaybackBackend {
    enum Failure: LocalizedError {
        case notThisPaksTrack(URL)
        case exited(String)
        case pak(String)

        var errorDescription: String? {
            switch self {
            case .notThisPaksTrack(let url): return "\(url) isn't one of this Pak's tracks."
            case .exited(let name): return "The \(name) Pak stopped running."
            case .pak(let message): return message
            }
        }
    }

    private enum Kind {
        case load(String), play, pause, resume, stop, seek(Double)
    }

    private struct Command {
        let kind: Kind
        let generation: Int
    }

    private(set) var state = PlaybackState.stopped
    private(set) var nowPlaying: NowPlaying?
    let capabilities: PlaybackCapabilities = []
    var onTrackEnd: (() -> Void)?
    var onLoadFailure: ((Error) -> Void)?

    private let transport: PakPlaybackTransport
    private let pakName: String
    private let trackID: (URL) -> String?
    private var loaded: (id: String, url: URL)?
    /// Whose sound the Pak said the visualizer can hear.
    private var audio: String?
    /// Bumped by every `load` and when the program exits; commands from an earlier one are dropped.
    private(set) var generation = 0
    /// Where the player was when it last said so, and when that was.
    private var position: Double = 0
    private var positionAt: TimeInterval = 0
    private var duration: Double = 0
    /// Commands given and not yet finished. While any are, the Pak's reports move the clock
    /// but not `state`, which already says what was asked for.
    private var pending = 0
    private var inflight: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private let commands: AsyncStream<Command>.Continuation
    /// Set when the program exited, so the next play loads the track into the new one first.
    private var needsReload = false

    init(transport: PakPlaybackTransport, name: String, trackID: @escaping (URL) -> String?) {
        self.transport = transport
        self.pakName = name
        self.trackID = trackID
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        transport.onPlaybackEvent = { [weak self] in self?.receive($0) }
        transport.onProgramExit = { [weak self] in self?.programExited() }
        pump = Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.run(command)
            }
        }
    }

    deinit {
        commands.finish()
        pump?.cancel()
    }

    var audioSource: PlaybackAudioSource? {
        switch audio {
        case PakAudioProcess.itself: return transport.audioProcessID.map(PlaybackAudioSource.processID)
        case PakAudioProcess.appleMusic: return .appleMusicPlayer
        default: return nil
        }
    }

    var currentTime: Double {
        guard state == .playing else { return position }
        let now = position + (ProcessInfo.processInfo.systemUptime - positionAt)
        // The clock doesn't run past the end while the Pak's `ended` is on its way.
        return duration > 0 ? min(now, duration) : now
    }

    // MARK: - PlaybackBackend

    func load(_ url: URL) throws {
        guard let id = trackID(url) else { throw Failure.notThisPaksTrack(url) }
        generation += 1
        inflight?.cancel()
        loaded = (id, url)
        audio = nil
        state = .stopped
        position = 0
        duration = 0
        needsReload = false
        nowPlaying = NowPlaying(url: url, title: pakName, duration: 0)
        enqueue(.load(id))
    }

    func play() {
        guard let loaded else { return }
        if state == .paused {
            resume()
            return
        }
        if needsReload {
            needsReload = false
            enqueue(.load(loaded.id))
        }
        state = .playing
        position = 0
        positionAt = ProcessInfo.processInfo.systemUptime
        enqueue(.play)
    }

    func pause() {
        switch state {
        case .playing:
            position = currentTime
            state = .paused
            enqueue(.pause)
        case .paused:
            resume()
        case .stopped:
            break
        }
    }

    func stop() {
        guard loaded != nil else { return }
        state = .stopped
        position = 0
        enqueue(.stop)
    }

    func seek(to seconds: Double) {
        guard loaded != nil, state != .stopped else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = target
        positionAt = ProcessInfo.processInfo.systemUptime
        enqueue(.seek(target))
    }

    private func resume() {
        state = .playing
        positionAt = ProcessInfo.processInfo.systemUptime
        enqueue(.resume)
    }

    // MARK: - Commands

    private func enqueue(_ kind: Kind) {
        pending += 1
        commands.yield(Command(kind: kind, generation: generation))
    }

    /// Sends one command, unless a later `load` has made it stale.
    private func run(_ command: Command) async {
        guard command.generation == generation else {
            pending -= 1
            return
        }
        let task = Task { @MainActor in await self.perform(command) }
        inflight = task
        await task.value
        pending -= 1
    }

    private func perform(_ command: Command) async {
        do {
            switch command.kind {
            case .load(let id):
                let result = try await transport.load(trackID: id)
                guard command.generation == generation, let url = loaded?.url else { return }
                audio = result.audio
                duration = result.duration ?? 0
                nowPlaying = NowPlaying(url: url, title: result.title ?? pakName, artist: result.artist, duration: duration)
            case .play: try await transport.command(PakMethod.play)
            case .pause: try await transport.command(PakMethod.pause)
            case .resume: try await transport.command(PakMethod.resume)
            case .stop: try await transport.command(PakMethod.stop)
            case .seek(let seconds): try await transport.seek(to: seconds)
            }
        } catch is CancellationError {
            // A newer load took over.
        } catch {
            guard command.generation == generation else { return }
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        state = .stopped
        position = 0
        onLoadFailure?(error)
    }

    // MARK: - What the Pak reports

    private func receive(_ event: PakPlaybackEvent) {
        // Late word about a track that's no longer the loaded one.
        guard let loaded, event.track == nil || event.track == loaded.id else { return }
        switch event.event {
        case PakPlaybackEvent.state:
            if let reported = event.position {
                position = max(0, reported)
                positionAt = ProcessInfo.processInfo.systemUptime
            }
            if let reported = event.duration, reported > 0, reported != duration, let now = nowPlaying {
                duration = reported
                nowPlaying = NowPlaying(url: now.url, title: now.title, artist: now.artist, duration: reported)
            }
            if pending == 0, let reported = event.state { state = Self.state(reported) }
        case PakPlaybackEvent.ended:
            state = .stopped
            position = 0
            onTrackEnd?()
        case PakPlaybackEvent.error:
            let message = event.message ?? "The \(pakName) Pak couldn't play this track."
            // With advice, the listener gets the same title and what-to-try as a built-in backend's.
            fail(event.advice.map { PlaybackAdvice(title: message, advice: $0) } ?? Failure.pak(message))
        default:
            break
        }
    }

    private static func state(_ reported: PakPlayerState) -> PlaybackState {
        switch reported {
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        }
    }

    /// The program ended mid-song: its player is gone. Commands still waiting would go to a
    /// fresh program that knows nothing of the track, so they're dropped, and the next play
    /// loads the track again first.
    private func programExited() {
        guard loaded != nil else { return }
        generation += 1
        inflight?.cancel()
        needsReload = true
        let wasActive = state != .stopped
        state = .stopped
        position = 0
        if wasActive { onLoadFailure?(Failure.exited(pakName)) }
    }
}
