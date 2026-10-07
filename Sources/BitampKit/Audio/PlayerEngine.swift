import AVFoundation

/// Plays one file through player → 10-band EQ → retro sound → output mixer → main mixer.
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

    var equalizerSettings = EqualizerSettings.flat {
        didSet { applyEqualizer() }
    }

    /// Crushes the music to 8-bit samples, or replaces it with a chip cover.
    var retroSound = RetroSound.off {
        didSet {
            retroKernel?.mode = retroSound
            startTranscription()
        }
    }

    /// How much of the song plays under the chiptune cover.
    var chipBlend = ChipBlend.low {
        didSet { retroKernel?.blend = chipBlend.level }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    private let retro = RetroAudioUnit.makeNode()
    private var retroKernel: RetroAudioUnit.Kernel? { (retro.auAudioUnit as? RetroAudioUnit)?.kernel }
    /// Carries volume and balance into the main mixer.
    private let output = AVAudioMixerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is thrown away, so stale completions are ignored.
    private var generation = 0
    /// The chip arrangement of the loaded file, and the background work filling it in, which
    /// starts the first time the file plays as a chiptune.
    private var score: ChipScore?
    private var transcription: NoteTranscription?

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
        retroKernel?.blend = chipBlend.level
        engine.attach(retro)
        engine.attach(output)
        output.volume = Float(volume * volume)
        // Compile Basic Pitch's model ahead of the first chiptune.
        DispatchQueue.global(qos: .utility).async { _ = BasicPitch.shared }

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    private func applyEqualizer() {
        let settings = equalizerSettings.clamped
        equalizer.bypass = !settings.enabled
        equalizer.globalGain = settings.preamp
        for (band, gain) in zip(equalizer.bands, settings.bands) {
            band.gain = gain
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
        retro.removeTap(onBus: 0)
        // The render thread is stopped, so the kernel can take a new score.
        transcription?.cancel()
        transcription = nil
        let score = ChipScore(duration: Double(file.length) / file.processingFormat.sampleRate)
        self.score = score
        retroKernel?.score = score

        let format = file.processingFormat
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: retro, format: format)
        engine.connect(retro, to: output, format: format)
        engine.connect(output, to: engine.mainMixerNode, format: format)
        // After the retro sound, so the visualizer shows what's playing.
        retro.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(analyzer))
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
        startTranscription()
    }

    /// Starts working out the loaded file's chip arrangement, once it's wanted.
    private func startTranscription() {
        guard retroSound == .chiptune, transcription == nil, let score, let url = track?.url else { return }
        do {
            let transcription = try NoteTranscription(url: url, score: score)
            transcription.prioritize(currentTime)
            transcription.start()
            self.transcription = transcription
        } catch {
            NSLog("Bitamp: couldn't transcribe \(url.path): \(error)")
            score.markUnusable()
        }
    }

    /// Once the player has rendered, works out which file frame plays at each render
    /// sample time and tells the chip, so it plays the score in step with the music.
    private func syncClock(generation: Int, attempts: Int = 0) {
        guard generation == self.generation, state == .playing, attempts < 100 else { return }
        if let offset = Self.clockOffset(player: player, startFrame: startFrame) {
            retroKernel?.setClock(offset: offset)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                MainActor.assumeIsolated { self?.syncClock(generation: generation, attempts: attempts + 1) }
            }
        }
    }

    /// The file frame at render sample time 0: the player's sample time counts from where
    /// it started, which was `startFrame` in the file.
    nonisolated static func clockOffset(player: AVAudioPlayerNode, startFrame: AVAudioFramePosition) -> Int64? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid
        else { return nil }
        return startFrame + playerTime.sampleTime - nodeTime.sampleTime
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
        retroKernel?.setClock(offset: nil)
        player.stop()
        if engine.isRunning { engine.pause() }
    }

    private func startPlayback(at frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        player.stop()
        retroKernel?.setClock(offset: nil)
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
        transcription?.prioritize(Double(frame) / file.processingFormat.sampleRate)
        syncClock(generation: generation)
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
            let metadata = await TrackMetadata.load(from: url)
            guard var track = self.track, track.url == url else { return }
            if let title = metadata.title { track.title = title }
            if let artist = metadata.artist { track.artist = artist }
            if let kbps = metadata.kbps { track.kbps = kbps }
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
