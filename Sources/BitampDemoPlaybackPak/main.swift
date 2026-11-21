import AVFoundation
import BitampPakSDK
import Foundation

/// Bitamp's demo of a Pak that plays its own audio (the `playback` capability). The tunes are
/// the Demo Pak's, but here the Pak makes the sound itself, in its own process, instead of
/// giving Bitamp a file to play. Bitamp tells it to load, play, pause, resume, stop and seek,
/// and the Pak reports what its player does. Package it with `scripts/make-pak.sh`; see
/// docs/PAK-SDK.md.

/// Where the reporter is kept: set by the runner on one thread, used by the player on the main one.
final class ReporterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PakPlaybackReporter?
    var reporter: PakPlaybackReporter? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The player: an `AVAudioPlayer`, whose finishing is told to its delegate on the main run
/// loop (which `PakRunner.run` keeps alive), and a timer that reports the position.
@MainActor
final class Player: NSObject, AVAudioPlayerDelegate {
    private let box: ReporterBox
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(box: ReporterBox) {
        self.box = box
    }

    /// Gets `file` ready, replacing whatever was playing. Returns its length in seconds.
    func load(_ file: URL) throws -> Double {
        stopReporting()
        player?.stop()
        let next = try AVAudioPlayer(contentsOf: file)
        next.delegate = self
        next.prepareToPlay()
        player = next
        return next.duration
    }

    func play() {
        player?.currentTime = 0
        player?.play()
        report(.playing)
        startReporting()
    }

    func pause() {
        player?.pause()
        stopReporting()
        report(.paused)
    }

    func resume() {
        player?.play()
        report(.playing)
        startReporting()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        player?.prepareToPlay()
        stopReporting()
        report(.stopped)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(seconds, player.duration))
        report(player.isPlaying ? .playing : .paused)
    }

    private func report(_ state: PakPlayerState) {
        box.reporter?.report(state, position: player?.currentTime ?? 0, duration: player?.duration)
    }

    /// Every half second while playing, so Bitamp's clock follows this player's.
    private func startReporting() {
        stopReporting()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player?.isPlaying == true else { return }
                self.report(.playing)
            }
        }
    }

    private func stopReporting() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopReporting()
            if flag { box.reporter?.ended() } else { box.reporter?.failed("The sound stopped before the end.") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            stopReporting()
            box.reporter?.failed(error?.localizedDescription ?? "The sound couldn't be played.")
        }
    }
}

final class DemoPlayback: PakProvider, @unchecked Sendable {
    private let box = ReporterBox()
    private var mainPlayer: Player?

    /// The player, made the first time it's wanted, on the main thread where it lives.
    @MainActor private func player() -> Player {
        if let mainPlayer { return mainPlayer }
        let made = Player(box: box)
        mainPlayer = made
        return made
    }
    private var cache = FileManager.default.temporaryDirectory

    func attach(_ reporter: PakPlaybackReporter) {
        box.reporter = reporter
    }

    func configure(_ context: PakContext) async throws -> PakAccountState {
        cache = context.cacheDirectory
        return .connected
    }

    func search(_ term: String) async throws -> [PakTrackInfo] {
        let term = term.trimmingCharacters(in: .whitespaces)
        return Tune.all
            .filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) || $0.composer.localizedCaseInsensitiveContains(term) }
            .map(info)
    }

    func track(id: String) async throws -> PakTrackInfo? {
        Tune.all.first { $0.id == id }.map(info)
    }

    func load(id: String) async throws -> PakPlaybackLoad {
        guard let tune = Tune.all.first(where: { $0.id == id }) else { throw PakFailure("There's no tune called \(id).") }
        let file = cache.appendingPathComponent("\(tune.id).wav")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Synth.render(tune, waveform: .triangle, to: file)
        }
        let duration = try await MainActor.run { try player().load(file) }
        // "self": the sound comes out of this process, so Bitamp's visualizer can listen to it.
        return PakPlaybackLoad(duration: duration, title: tune.title, artist: tune.composer, audio: PakAudioProcess.itself)
    }

    func play() async throws { await MainActor.run { player().play() } }
    func pause() async throws { await MainActor.run { player().pause() } }
    func resume() async throws { await MainActor.run { player().resume() } }
    func stop() async throws { await MainActor.run { player().stop() } }
    func seek(to seconds: Double) async throws { await MainActor.run { player().seek(to: seconds) } }

    private func info(_ tune: Tune) -> PakTrackInfo {
        PakTrackInfo(id: tune.id, title: tune.title, artist: tune.composer, album: "Demo Playback", duration: tune.duration)
    }
}

PakRunner.run(DemoPlayback())
