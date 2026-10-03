import Foundation

/// Ties the queue to the engine: what's playing, what plays next, and the saved settings
/// for volume, balance, shuffle and repeat.
@MainActor
final class PlaybackController {
    let engine: PlayerEngine
    private(set) var queue = PlayQueue()
    let info = TrackInfoStore()
    private let preferences: Preferences
    /// Short, marquee-sized messages about files that couldn't be opened.
    var onError: ((String) -> Void)?

    init(engine: PlayerEngine, preferences: Preferences) {
        self.engine = engine
        self.preferences = preferences
        queue.repeats = preferences.repeats
        queue.setShuffled(preferences.shuffle)
        engine.volume = preferences.volume
        engine.balance = preferences.balance
        engine.equalizerSettings = preferences.equalizer
        engine.onTrackEnd = { [weak self] in self?.trackEnded() }
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
        let files = AudioFiles.expand(urls)
        guard !files.isEmpty else {
            onError?("NO AUDIO FILES THERE")
            return
        }
        queue.replace(with: files)
        loadCurrent(andPlay: true)
    }

    /// Adds to the queue. Starts playing if nothing was loaded yet.
    func enqueue(_ urls: [URL]) {
        let files = AudioFiles.expand(urls)
        guard !files.isEmpty else {
            onError?("NO AUDIO FILES THERE")
            return
        }
        let wasEmpty = queue.isEmpty
        queue.append(files)
        if wasEmpty { loadCurrent(andPlay: true) }
    }

    func play() {
        if engine.track == nil {
            loadCurrent(andPlay: true)
        } else {
            engine.play()
        }
    }

    func playItem(at index: Int) {
        queue.select(index)
        loadCurrent(andPlay: true)
    }

    // MARK: - Editing the queue

    func insert(_ urls: [URL], at index: Int) {
        let files = AudioFiles.expand(urls)
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
        let missing = queue.items.indices.filter { !FileManager.default.fileExists(atPath: queue.items[$0].path) }
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
        let files = AudioFiles.expand([url])
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
        let files = AudioFiles.expand([Self.sessionURL])
        guard !files.isEmpty else { return }
        queue.replace(with: files)
        if let index = preferences.queueIndex, files.indices.contains(index) { queue.select(index) }
        loadCurrent(andPlay: false)
    }

    // Like the classic players, changing tracks while stopped just loads the new one.

    func next() {
        guard queue.next() != nil else { return }
        loadCurrent(andPlay: engine.state != .stopped)
    }

    func previous() {
        guard queue.previous() != nil else { return }
        loadCurrent(andPlay: engine.state != .stopped)
    }

    private func trackEnded() {
        guard queue.next() != nil else { return }
        loadCurrent(andPlay: true)
    }

    /// Loads the queue's current track, skipping forward past files that won't open.
    private func loadCurrent(andPlay play: Bool) {
        for _ in 0..<queue.count {
            guard let url = queue.current else { return }
            do {
                try engine.load(url)
                if play { engine.play() }
                return
            } catch {
                onError?("CAN'T OPEN \(url.lastPathComponent)")
                guard queue.next() != nil else { return }
            }
        }
    }
}
