import Foundation

/// Ties the queue to the engine: what's playing, what plays next, and the saved settings
/// for volume, balance, shuffle and repeat. Local files play through `engine`; a Pak's
/// tracks play through the engine or the Pak's own backend, whichever it says.
@MainActor
final class PlaybackController {
    let engine: PlayerEngine
    let paks: PakRegistry
    /// What plays the current track. The engine until a Pak's backend takes over.
    private(set) var player: PlaybackBackend
    private(set) var queue = PlayQueue()
    let info = TrackInfoStore()
    private let preferences: Preferences
    /// Short, marquee-sized messages about files that couldn't be opened.
    var onError: ((String) -> Void)?
    /// Tracks in a row that turned out not to play after loading. Stops the skipping
    /// once every track has failed.
    private var lateFailures = 0
    /// The queue item last loaded, whichever backend plays it.
    private var loadedURL: URL?
    /// The Pak track whose audio is on its way, while it is.
    private(set) var fetching: URL?
    /// Bumped on every load and stop, so a fetch that's been overtaken is dropped.
    private var fetchGeneration = 0

    enum LoadError: Error {
        case noPak(URL)
        case ejected(Pak)
    }

    init(engine: PlayerEngine, preferences: Preferences, paks: PakRegistry? = nil) {
        self.engine = engine
        self.paks = paks ?? PakRegistry()
        self.player = engine
        self.preferences = preferences
        queue.repeats = preferences.repeats
        queue.setShuffled(preferences.shuffle)
        engine.volume = preferences.volume
        engine.balance = preferences.balance
        engine.equalizerSettings = preferences.equalizer
        engine.retroSound = preferences.retroSound
        engine.chipBlend = preferences.chipBlend
        engine.onTrackEnd = { [weak self] in self?.trackEnded() }
        // Only inserted Paks are asked; an ejected one isn't contacted at all.
        info.loadExternal = { [weak paks] url in
            guard let pak = paks?.pak(for: url) else { return nil }
            let track = await pak.metadata(for: url)
            return TrackMetadata(title: track?.title, artist: track?.artist, duration: track?.duration)
        }
    }

    /// Folders and playlists expanded, keeping tracks the installed Paks can play. The
    /// titles a playlist saved fill in the playlist straight away.
    private func expand(_ urls: [URL]) -> [URL] {
        let entries = AudioFiles.expandEntries(urls, schemes: paks.schemes)
        for entry in entries {
            // A title saved with an unknown length was only the file name, written before
            // the tags were read; leave it so they're read now.
            guard let title = entry.title, let duration = entry.duration else { continue }
            info.seedIfMissing(TrackMetadata(title: title, duration: duration), for: entry.url)
        }
        return entries.map(\.url)
    }

    var volume: Double {
        get { engine.volume }
        set {
            engine.volume = min(max(newValue, 0), 1)
            preferences.volume = engine.volume
        }
    }

    var balance: Double {
        get { engine.balance }
        set {
            engine.balance = min(max(newValue, -1), 1)
            preferences.balance = engine.balance
        }
    }

    var shuffle: Bool {
        get { queue.shuffled }
        set {
            queue.setShuffled(newValue)
            preferences.shuffle = newValue
        }
    }

    var repeats: Bool {
        get { queue.repeats }
        set {
            queue.repeats = newValue
            preferences.repeats = newValue
        }
    }

    var chipBlend: ChipBlend {
        get { engine.chipBlend }
        set {
            engine.chipBlend = newValue
            preferences.chipBlend = newValue
        }
    }

    var retroSound: RetroSound {
        get { engine.retroSound }
        set {
            engine.retroSound = newValue
            preferences.retroSound = newValue
        }
    }

    var equalizer: EqualizerSettings {
        get { engine.equalizerSettings }
        set {
            engine.equalizerSettings = newValue.clamped
            preferences.equalizer = engine.equalizerSettings
        }
    }

    var customPresets: [EqualizerPreset] {
        get { preferences.customPresets }
        set { preferences.customPresets = newValue }
    }

    /// Replaces the queue with `urls`, expanding folders, and starts playing.
    func open(_ urls: [URL]) {
        let files = expand(urls)
        guard !files.isEmpty else {
            onError?("NO AUDIO FILES THERE")
            return
        }
        queue.replace(with: files)
        loadCurrent(andPlay: true)
    }

    /// Adds to the queue. Starts playing if nothing was loaded yet.
    func enqueue(_ urls: [URL]) {
        let files = expand(urls)
        guard !files.isEmpty else {
            onError?("NO AUDIO FILES THERE")
            return
        }
        let wasEmpty = queue.isEmpty
        queue.append(files)
        if wasEmpty { loadCurrent(andPlay: true) }
    }

    func play() {
        if player.nowPlaying == nil {
            if fetching == nil { loadCurrent(andPlay: true) }
        } else {
            player.play()
        }
    }

    /// Stops, including a track that's still being fetched.
    func stop() {
        fetchGeneration += 1
        fetching = nil
        player.stop()
    }

    /// Sets the queue as given, without expanding folders or checking the files exist,
    /// and makes item `current` the current one. For rendering and tests.
    func setQueueItems(_ urls: [URL], current: Int? = nil) {
        queue.replace(with: urls)
        if let current { queue.select(current) }
    }

    func playItem(at index: Int) {
        queue.select(index)
        loadCurrent(andPlay: true)
    }

    // MARK: - Editing the queue

    func insert(_ urls: [URL], at index: Int) {
        let files = expand(urls)
        let wasEmpty = queue.isEmpty
        queue.insert(files, at: index)
        if wasEmpty && !files.isEmpty { loadCurrent(andPlay: false) }
    }

    func remove(_ indexes: IndexSet) {
        queue.remove(indexes)
    }

    /// Keeps only `indexes`.
    func crop(to indexes: IndexSet) {
        queue.remove(IndexSet(0..<queue.count).subtracting(indexes))
    }

    func removeAll() {
        queue.removeAll()
    }

    func removeMissingFiles() {
        let missing = queue.items.indices.filter {
            queue.items[$0].isFileURL && !FileManager.default.fileExists(atPath: queue.items[$0].path)
        }
        queue.remove(IndexSet(missing))
    }

    @discardableResult
    func move(_ indexes: IndexSet, by offset: Int) -> IndexSet {
        queue.move(indexes, by: offset)
    }

    enum SortKey {
        case title, fileName, path
    }

    func sort(by key: SortKey) {
        switch key {
        case .title: queue.sort { info.displayName(for: $0) }
        case .fileName: queue.sort { $0.lastPathComponent }
        case .path: queue.sort { $0.path }
        }
    }

    func reverse() { queue.reverse() }
    func randomize() { queue.randomize() }

    // MARK: - Playlist files

    /// Replaces the queue with a playlist's tracks, without starting playback.
    func loadPlaylist(_ url: URL) {
        let files = expand([url])
        guard !files.isEmpty else {
            onError?("NO PLAYABLE FILES IN \(url.lastPathComponent)")
            return
        }
        queue.replace(with: files)
        loadCurrent(andPlay: false)
    }

    func savePlaylist(to url: URL) throws {
        let entries = queue.items.map { item in
            M3U.Entry(url: item, title: info.metadata(for: item)?.displayName(for: item), duration: info.duration(for: item))
        }
        try M3U.write(entries).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Where the queue is kept between launches.
    static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bitamp", isDirectory: true)
            .appendingPathComponent("Queue.m3u8")
    }

    func saveSession() {
        let url = Self.sessionURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? savePlaylist(to: url)
        preferences.queueIndex = queue.currentIndex
    }

    /// Reloads last session's queue and loads (doesn't play) its current track.
    func restoreSession() {
        let files = expand([Self.sessionURL])
        guard !files.isEmpty else { return }
        queue.replace(with: files)
        if let index = preferences.queueIndex, files.indices.contains(index) { queue.select(index) }
        loadCurrent(andPlay: false)
    }

    // Like the classic players, changing tracks while stopped just loads the new one.

    func next() {
        guard queue.next() != nil else { return }
        loadCurrent(andPlay: player.state != .stopped)
    }

    func previous() {
        guard queue.previous() != nil else { return }
        loadCurrent(andPlay: player.state != .stopped)
    }

    private func trackEnded() {
        guard queue.next() != nil else { return }
        loadCurrent(andPlay: true)
    }

    /// The backend found out after loading that the track won't play: skip it, as
    /// `loadCurrent` skips files that won't open.
    private func loadFailed(_ error: Error) {
        guard let url = queue.current else { return }
        onError?("CAN'T PLAY \(info.displayName(for: url))")
        NSLog("Bitamp: couldn't play \(url): \(error)")
        lateFailures += 1
        guard lateFailures < queue.count, queue.next() != nil else {
            lateFailures = 0
            return
        }
        loadCurrent(andPlay: true, afterFailure: true)
    }

    /// Loads the queue's current track, skipping forward past files that won't open.
    /// However many it skips, it reports them once.
    private func loadCurrent(andPlay play: Bool, afterFailure: Bool = false) {
        if !afterFailure { lateFailures = 0 }
        var skipped: [String] = []
        defer { if let message = Self.skipMessage(skipped) { onError?(message) } }
        for _ in 0..<queue.count {
            guard let url = queue.current else { return }
            do {
                try load(url, andPlay: play)
                return
            } catch LoadError.ejected(let pak) {
                skipped.append("\(pak.name) PAK IS EJECTED")
            } catch {
                skipped.append("CAN'T OPEN \(url.lastPathComponent)")
            }
            guard queue.next() != nil else { return }
        }
    }

    /// One message for a run of skipped tracks: the reason when they all share one,
    /// otherwise the first and a count of the rest.
    static func skipMessage(_ reasons: [String]) -> String? {
        guard let first = reasons.first else { return nil }
        if Set(reasons).count == 1 { return first }
        return "\(first) (+\(reasons.count - 1) MORE SKIPPED)"
    }

    /// The Pak playing the current track, when it plays the audio itself rather than
    /// through the engine.
    var playingPak: Pak? {
        guard player.nowPlaying != nil || fetching != nil, let url = loadedURL else { return nil }
        return paks.owner(of: url)
    }

    /// Why a control does nothing for the current track, or nil when it works: a Pak
    /// that plays its own audio keeps Bitamp's volume, equalizer and Retro Sound out.
    func limitation(_ capability: PlaybackCapabilities) -> String? {
        guard !player.capabilities.contains(capability) else { return nil }
        let name = playingPak?.name ?? "THIS SONG"
        if capability == .volume { return "\(name) PLAYS AT YOUR MAC'S VOLUME" }
        if capability == .equalizer { return "THE EQ CAN'T REACH \(name)" }
        if capability == .retroSound { return "RETRO SOUND CAN'T REACH \(name)" }
        return "\(name) CAN'T DO THAT"
    }

    /// Inserts or ejects a Pak. Ejecting the one that's playing stops it.
    func setInserted(_ inserted: Bool, _ pak: Pak) {
        paks.setInserted(inserted, pak)
        if inserted { info.retryMissing() }
        if !inserted, playingPak === pak { stop() }
    }

    /// Loads `url` into whichever backend plays it, stopping the old one if that changes,
    /// and plays it if asked. A Pak track that has to be fetched loads when it arrives.
    private func load(_ url: URL, andPlay play: Bool) throws {
        fetchGeneration += 1
        fetching = nil
        var backend: PlaybackBackend = engine
        var source = url
        var fetch: (@MainActor () async throws -> URL)?
        if !url.isFileURL {
            guard let pak = paks.owner(of: url) else { throw LoadError.noPak(url) }
            guard paks.isInserted(pak) else { throw LoadError.ejected(pak) }
            switch try pak.playback(for: url) {
            case .stream(let stream): source = stream
            case .fetch(let later): fetch = later
            case .backend(let own): backend = own
            }
        }
        if backend !== player {
            player.stop()
            player = backend
            backend.onTrackEnd = { [weak self] in self?.trackEnded() }
            backend.onLoadFailure = { [weak self] error in self?.loadFailed(error) }
        }
        loadedURL = url
        if let fetch {
            engine.unload()
            fetching = url
            let generation = fetchGeneration
            Task {
                do {
                    let file = try await fetch()
                    guard generation == fetchGeneration else { return }
                    fetching = nil
                    try loadStream(file, for: url)
                    if play { engine.play() }
                } catch {
                    guard generation == fetchGeneration else { return }
                    fetching = nil
                    loadFailed(error)
                }
            }
            return
        }
        if source != url {
            try loadStream(source, for: url)
        } else {
            try backend.load(source)
        }
        if play { backend.play() }
    }

    /// Loads a Pak's audio file into the engine under the Pak track's title.
    private func loadStream(_ file: URL, for url: URL) throws {
        try engine.load(file)
        if let metadata = info.metadata(for: url) {
            engine.retitle(metadata.title, artist: metadata.artist)
        }
    }
}
