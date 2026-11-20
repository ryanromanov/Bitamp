import AVFoundation

/// Plays one file through player → 10-band EQ → retro sound → output mixer → main mixer.
///
/// Pausing and seeking stop the player node and reschedule from a frame, so the
/// position is always `startFrame` plus however far the node has played since.
@MainActor
final class PlayerEngine: PlaybackBackend {
    typealias State = PlaybackState
    typealias Track = NowPlaying

    static let eqFrequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]

    private(set) var state = State.stopped
    private(set) var track: Track?
    var nowPlaying: NowPlaying? { track }
    let capabilities = PlaybackCapabilities.all
    /// Called after a track plays to the end and the engine has stopped.
    var onTrackEnd: (() -> Void)?
    /// Never called: the engine knows at `load` whether a file opens.
    var onLoadFailure: ((Error) -> Void)?
    /// Called when playback moved on to the track given to `scheduleNext` without stopping,
    /// with that track's URL. The engine is already playing it.
    var onTrackAdvance: ((URL) -> Void)?
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
            if retroSound == .chiptune {
                Self.warmUpTranscriber()
                reloadForChiptune()
            }
            startTranscription()
        }
    }

    /// How much of the song plays under the chiptune cover.
    var chipBlend = ChipBlend.low {
        didSet { retroKernel?.blend = chipBlend.level }
    }

    private let engine: AVAudioEngine
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
    private(set) var generation = 0
    /// The chip arrangement of the loaded file, and the background work filling it in, which
    /// starts the first time the file plays as a chiptune.
    private var score: ChipScore?
    private var transcription: NoteTranscription?
    /// The next track, already scheduled on the player to follow this one with no gap.
    private var nextFile: AVAudioFile?
    private var nextURL: URL?
    /// The loaded file got here by playing on from the last one, so the chip score (made
    /// when a file is loaded) isn't for it.
    private var loadedByAdvance = false

    /// `engine` is the audio engine to use; tests give one that renders offline.
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
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

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    /// Loads Basic Pitch's model ahead of the first chiptune, once chiptune is chosen, so
    /// listeners who never use it don't pay for it at every launch.
    private static func warmUpTranscriber() {
        DispatchQueue.global(qos: .utility).async { _ = BasicPitch.shared }
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
        if let stagedTime { return stagedTime }
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
            // Before the first render the node time can exist without a valid sample time, and
            // asking the player about it raises an exception.
            guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
                  let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid
            else { return startFrame }
            return min(startFrame + max(0, playerTime.sampleTime), file?.length ?? 0)
        }
    }

    /// Shows `track` as playing at `seconds`, without loading or playing anything.
    /// For rendering screenshots.
    func stage(_ track: Track, at seconds: Double) {
        self.track = track
        state = .playing
        stagedTime = seconds
    }

    private var stagedTime: Double?

    /// Stops and forgets the loaded file, so nothing shows as loaded.
    func unload() {
        stop()
        forgetNext()
        transcription?.cancel()
        transcription = nil
        file = nil
        track = nil
        stagedTime = nil
    }

    /// Shows a title and artist other than the file's own, such as a Pak's for a file it
    /// fetched. Tags the file turns out to have still win.
    func retitle(_ title: String?, artist: String?) {
        guard var track else { return }
        if let title { track.title = title }
        if let artist { track.artist = artist }
        self.track = track
    }

    func load(_ url: URL) throws {
        stagedTime = nil
        let file = try AVAudioFile(forReading: url)
        stop()
        forgetNext()
        loadedByAdvance = false
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
        track = Self.makeTrack(url: url, file: file)
        loadMetadata(for: url)
        startTranscription()
    }

    private static func makeTrack(url: URL, file: AVAudioFile) -> Track {
        let fileFormat = file.fileFormat
        let duration = Double(file.length) / fileFormat.sampleRate
        return Track(
            url: url, title: url.deletingPathExtension().lastPathComponent, artist: nil,
            duration: duration, sampleRate: fileFormat.sampleRate,
            channels: Int(fileFormat.channelCount), kbps: averageKbps(url: url, duration: duration))
    }

    // MARK: - Gapless

    /// The track scheduled to follow this one, if any.
    var scheduledNext: URL? { nextURL }

    /// Queues `url` on the player right behind the current track, so the music runs on with
    /// no gap, no click and no rebuilding of the audio chain. Only for a local file in the
    /// same format as this one (another sample rate or channel count needs the chain
    /// rebuilt), and not with the chiptune cover, which is worked out per file. Returns
    /// whether it was queued; if not, the track just changes the usual way when this ends.
    @discardableResult
    func scheduleNext(_ url: URL) -> Bool {
        guard state == .playing, nextFile == nil, retroSound != .chiptune, url.isFileURL,
              let file, let next = try? AVAudioFile(forReading: url),
              next.processingFormat == file.processingFormat, next.length > 0
        else { return false }
        player.scheduleFile(next, at: nil, completionCallbackType: .dataPlayedBack,
                            completionHandler: Self.completion(generation: generation, owner: self))
        nextFile = next
        nextURL = url
        return true
    }

    /// Takes back a track queued by `scheduleNext` (the queue changed): the current one is
    /// scheduled again from where it is, which can click once.
    func cancelNext() {
        guard nextFile != nil, state == .playing else { return }
        startPlayback(at: currentFrame)
    }

    private func forgetNext() {
        nextFile = nil
        nextURL = nil
    }

    /// The current file has played out and the queued one is already sounding.
    private func advance(to next: AVAudioFile, url: URL) {
        guard let old = file else { return }
        // The player's clock keeps running across the two files; the new file's position is
        // that clock less what the old file took.
        startFrame -= old.length
        file = next
        forgetNext()
        track = Self.makeTrack(url: url, file: next)
        loadedByAdvance = true
        score = ChipScore(duration: Double(next.length) / next.processingFormat.sampleRate)
        loadMetadata(for: url)
        onTrackAdvance?(url)
    }

    /// The chiptune cover needs a score made when the file was loaded; a file reached by
    /// playing on has none, so it's loaded again and picked up where it was.
    private func reloadForChiptune() {
        guard loadedByAdvance, let url = track?.url, file != nil else { return }
        let seconds = currentTime
        let wasPlaying = state == .playing
        guard (try? load(url)) != nil else { return }
        if wasPlaying, let file {
            startPlayback(at: AVAudioFramePosition(seconds * file.processingFormat.sampleRate))
        }
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
        forgetNext()
        retroKernel?.setClock(offset: nil)
        player.stop()
        if engine.isRunning { engine.pause() }
    }

    private func startPlayback(at frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        player.stop()
        forgetNext()
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

    /// The scheduled audio of generation `finishedGeneration` has been heard to the end.
    /// Called from the player's completion handler; tests call it, since offline rendering
    /// has no hardware to hear the audio.
    func segmentFinished(_ finishedGeneration: Int) {
        guard finishedGeneration == generation, state == .playing else { return }
        if let next = nextFile, let url = nextURL {
            advance(to: next, url: url)
        } else {
            trackEnded()
        }
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
