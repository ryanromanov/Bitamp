import AVFoundation

/// Plays one file through player → 10-band EQ → output mixer → main mixer.
///
/// Pausing and seeking stop the player node and reschedule from a frame, so the
/// position is always `startFrame` plus however far the node has played since.
@MainActor
final class PlayerEngine {
    enum State {
        case stopped, playing, paused
    }

    struct Track {
        let url: URL
        var title: String
        var artist: String?
        let duration: Double
        let sampleRate: Double
        let channels: Int
        var kbps: Int?
    }

    static let eqFrequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]

    private(set) var state = State.stopped
    private(set) var track: Track?
    /// Called after a track plays to the end and the engine has stopped.
    var onTrackEnd: (() -> Void)?
    let analyzer = SpectrumAnalyzer()

    /// 0...1, applied on a squared curve so the slider feels even.
    var volume: Double = 0.75 {
        didSet { output.volume = Float(volume * volume) }
    }

    /// -1 (left) ... 1 (right).
    var balance: Double = 0 {
        didSet { output.pan = Float(balance) }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    /// Carries volume and balance into the main mixer.
    private let output = AVAudioMixerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is thrown away, so stale completions are ignored.
    private var generation = 0

    init() {
        for (band, frequency) in zip(equalizer.bands, Self.eqFrequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        engine.attach(player)
        engine.attach(equalizer)
        engine.attach(output)
        output.volume = Float(volume * volume)

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    var currentTime: Double {
        guard let file else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    private var currentFrame: AVAudioFramePosition {
        switch state {
        case .stopped:
            return 0
        case .paused:
            return pausedFrame
        case .playing:
            guard let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime)
            else { return startFrame }
            return min(startFrame + max(0, playerTime.sampleTime), file?.length ?? 0)
        }
    }

    func load(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        stop()
        engine.stop()
        equalizer.removeTap(onBus: 0)

        let format = file.processingFormat
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: output, format: format)
        engine.connect(output, to: engine.mainMixerNode, format: format)
        equalizer.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(analyzer))
        engine.prepare()

        self.file = file
        analyzer.sampleRate = format.sampleRate
        let fileFormat = file.fileFormat
        let duration = Double(file.length) / fileFormat.sampleRate
        track = Track(
            url: url, title: url.deletingPathExtension().lastPathComponent, artist: nil,
            duration: duration, sampleRate: fileFormat.sampleRate,
            channels: Int(fileFormat.channelCount), kbps: Self.averageKbps(url: url, duration: duration))
        loadMetadata(for: url)
    }

    /// Resumes when paused; otherwise starts the track from the top.
    func play() {
        guard file != nil else { return }
        startPlayback(at: state == .paused ? pausedFrame : 0)
    }

    /// Toggles between playing and paused.
    func pause() {
        switch state {
        case .playing:
            pausedFrame = currentFrame
            halt()
            state = .paused
        case .paused:
            startPlayback(at: pausedFrame)
        case .stopped:
            break
        }
    }

    func stop() {
        halt()
        pausedFrame = 0
        state = .stopped
    }

    func seek(to seconds: Double) {
        guard let file, state != .stopped else { return }
        let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        if state == .playing {
            startPlayback(at: frame)
        } else {
            pausedFrame = min(frame, file.length)
        }
    }

    private func halt() {
        generation += 1
        player.stop()
        if engine.isRunning { engine.pause() }
    }

    private func startPlayback(at frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        player.stop()
        let frame = min(max(0, frame), file.length)
        guard frame < file.length else {
            trackEnded()
            return
        }
        startFrame = frame
        player.scheduleSegment(
            file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.completion(generation: generation, owner: self))
        do {
            try engine.start()
        } catch {
            NSLog("Bitamp: couldn't start audio engine: \(error)")
            stop()
            return
        }
        player.play()
        state = .playing
    }

    private func segmentFinished(_ finishedGeneration: Int) {
        guard finishedGeneration == generation, state == .playing else { return }
        trackEnded()
    }

    private func trackEnded() {
        stop()
        onTrackEnd?()
    }

    /// The output device changed and the engine stopped itself; pick up where we were.
    private func configurationChanged() {
        guard state == .playing else { return }
        startPlayback(at: currentFrame)
    }

    private func loadMetadata(for url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            var title: String?
            var artist: String?
            for item in (try? await asset.load(.commonMetadata)) ?? [] {
                switch item.commonKey {
                case .commonKeyTitle?: title = try? await item.load(.stringValue)
                case .commonKeyArtist?: artist = try? await item.load(.stringValue)
                default: break
                }
            }
            var kbps: Int?
            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
               let rate = try? await audioTrack.load(.estimatedDataRate), rate > 0 {
                kbps = Int((rate / 1000).rounded())
            }
            guard var track = self.track, track.url == url else { return }
            if let title, !title.isEmpty { track.title = title }
            if let artist, !artist.isEmpty { track.artist = artist }
            if let kbps { track.kbps = kbps }
            self.track = track
        }
    }

    /// File size over duration, used until the asset reports a data rate.
    private static func averageKbps(url: URL, duration: Double) -> Int? {
        guard duration > 0,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int((Double(size) * 8 / duration / 1000).rounded())
    }

    // These closures run off the main thread, so build them outside the main actor.

    private nonisolated static func tapBlock(_ analyzer: SpectrumAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in analyzer.process(buffer) }
    }

    private nonisolated static func completion(
        generation: Int, owner: PlayerEngine
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak owner] _ in
            let owner = owner
            Task { @MainActor in owner?.segmentFinished(generation) }
        }
    }
}
