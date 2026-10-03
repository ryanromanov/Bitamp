import Foundation

/// Ties the queue to the engine: what's playing, what plays next, and the saved settings
/// for volume, balance, shuffle and repeat.
@MainActor
final class PlaybackController {
    let engine: PlayerEngine
    private(set) var queue = PlayQueue()
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
