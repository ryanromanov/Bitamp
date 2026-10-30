import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// Notes about one song as the window shows them: the words, with "[1]"-style marks after
/// what each source supports, and the sources those marks number.
struct BackstoryNotes: Codable, Equatable {
    var text = ""
    var sources: [BackstorySource] = []

    mutating func apply(_ update: BackstoryUpdate) {
        switch update {
        case .text(let words):
            text += Self.plain(words)
        case .cite(let cited):
            var numbers: [Int] = []
            for source in cited {
                if let index = sources.firstIndex(where: { $0.url == source.url }) {
                    numbers.append(index + 1)
                } else {
                    sources.append(source)
                    numbers.append(sources.count)
                }
            }
            guard !numbers.isEmpty else { return }
            // After the cited words, before any space or line break that followed them.
            let trailing = text.reversed().prefix { $0 == " " || $0 == "\n" }.count
            let mark = " [" + numbers.map(String.init).joined(separator: ",") + "]"
            text.insert(contentsOf: mark, at: text.index(text.endIndex, offsetBy: -trailing))
        }
    }

    /// The words as the pixel font draws them: no markdown emphasis or headings, and
    /// typographic punctuation made plain, so nothing falls back to another font.
    static func plain(_ text: String) -> String {
        var text = text
        for (fancy, plain) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                               ("\u{2014}", " - "), ("\u{2013}", "-"), ("\u{2026}", "..."), ("\u{00A0}", " "),
                               ("*", ""), ("#", ""), ("`", "")] {
            text = text.replacingOccurrences(of: fancy, with: plain)
        }
        return text
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Notes already written, so a song played again shows them at once and costs nothing.
/// Kept in memory and as small JSON files in Bitamp's caches folder.
final class BackstoryCache {
    private let folder: URL?
    private var memory: [String: BackstoryNotes] = [:]

    init(folder: URL?) {
        self.folder = folder
    }

    static func standard() -> BackstoryCache {
        BackstoryCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ryanromanov.Bitamp/BackstoryNotes", isDirectory: true))
    }

    static func key(_ track: PakNowPlaying, _ identity: String) -> String {
        let name = [identity, track.artist ?? "", track.title, track.album ?? ""].map { $0.lowercased() }.joined(separator: "\n")
        return SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func notes(for track: PakNowPlaying, identity: String) -> BackstoryNotes? {
        let key = Self.key(track, identity)
        if let notes = memory[key] { return notes }
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("\(key).json")),
              let notes = try? JSONDecoder().decode(BackstoryNotes.self, from: data) else { return nil }
        memory[key] = notes
        return notes
    }

    func save(_ notes: BackstoryNotes, for track: PakNowPlaying, identity: String) {
        let key = Self.key(track, identity)
        memory[key] = notes
        guard let folder, let data = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
    }
}

/// Follows what's playing for the Backstory window, and looks songs up when the Pak's
/// setting says: after a song has played two seconds ("Every track"), or when asked.
/// Lookups start only while the window is open and the Pak inserted, since each one costs.
@MainActor
final class BackstorySession {
    enum Phase: Equatable {
        /// Nothing is playing.
        case idle
        /// Reading the song's tags.
        case reading
        /// The song has no title or artist to look up.
        case untagged
        /// There's no key yet.
        case needsSetup
        /// Looking up is off, and nothing was saved for this song.
        case off
        /// "Every track": waiting for the song to play long enough.
        case waiting
        /// "When I ask": waiting for the button.
        case ready
        /// The notes are arriving.
        case looking
        case done
        case failed(String, badKey: Bool)
    }

    /// How long a song plays before it's looked up, so skipping through costs nothing.
    static let delay: TimeInterval = 2

    let pak: BackstoryPak
    private let cache: BackstoryCache
    private let clock: () -> TimeInterval
    /// What's playing: the queue item, and whether it's playing now.
    var current: () -> (url: URL?, playing: Bool) = { (nil, false) }
    /// A queue item's tags and picture. Nil tags means nothing to look up.
    var describe: (URL) async -> (PakNowPlaying?, CGImage?) = { _ in (nil, nil) }
    var onChange: (() -> Void)?

    private(set) var phase = Phase.idle
    private(set) var track: PakNowPlaying?
    private(set) var artwork: CGImage?
    private(set) var notes = BackstoryNotes()
    /// Seconds the current song has spent playing.
    private(set) var played: TimeInterval = 0
    private var trackURL: URL?
    private var lastTick: TimeInterval?
    private var task: Task<Void, Never>?

    init(pak: BackstoryPak, cache: BackstoryCache, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pak = pak
        self.cache = cache
        self.clock = clock
    }

    var secondsUntilLookup: Int {
        max(1, Int((Self.delay - played).rounded(.up)))
    }

    /// Call often, about every frame. `active` is whether lookups may start now: the
    /// window is open and the Pak inserted.
    func update(active: Bool) {
        let now = clock()
        let elapsed = lastTick.map { now - $0 } ?? 0
        lastTick = now
        let (url, playing) = current()
        guard url == trackURL else {
            switchTo(url)
            return
        }
        if playing { played += elapsed }
        if phase == .waiting {
            if active && played >= Self.delay {
                lookUp()
            } else if playing {
                onChange?()
            }
        }
    }

    /// Looks the song up now, even if it was before ("Ask again").
    func lookUp() {
        guard let track else { return }
        guard let service = pak.service() else {
            phase = .needsSetup
            onChange?()
            return
        }
        task?.cancel()
        let identity = pak.identity
        notes = BackstoryNotes()
        phase = .looking
        onChange?()
        task = Task { [weak self] in
            do {
                for try await update in service.notes(for: track) {
                    guard let self, !Task.isCancelled else { return }
                    self.notes.apply(update)
                    self.onChange?()
                }
                guard let self, !Task.isCancelled else { return }
                if self.notes.isEmpty {
                    self.phase = .failed("No notes came back. Try again.", badKey: false)
                } else {
                    self.phase = .done
                    self.cache.save(self.notes, for: track, identity: identity)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription, badKey: error as? BackstoryError == .badKey)
            }
            self?.onChange?()
        }
    }

    /// Settings changed: shows what fits them, unless notes are on their way or shown.
    func settingsChanged() {
        guard phase != .looking, phase != .done, phase != .reading, phase != .idle else {
            onChange?()
            return
        }
        settle()
    }

    private func switchTo(_ url: URL?) {
        task?.cancel()
        task = nil
        trackURL = url
        played = 0
        track = nil
        artwork = nil
        notes = BackstoryNotes()
        phase = url == nil ? .idle : .reading
        onChange?()
        guard let url else { return }
        Task { [weak self] in
            guard let self else { return }
            let (track, artwork) = await self.describe(url)
            guard self.trackURL == url else { return }
            self.track = track
            self.artwork = artwork
            self.settle()
        }
    }

    /// What to show for the song, short of looking it up.
    private func settle() {
        defer { onChange?() }
        guard let track else {
            phase = trackURL == nil ? .idle : .untagged
            return
        }
        if let saved = cache.notes(for: track, identity: pak.identity) {
            notes = saved
            phase = .done
            return
        }
        notes = BackstoryNotes()
        switch pak.lookup {
        case .off: phase = .off
        case _ where pak.service() == nil: phase = .needsSetup
        case .everyTrack: phase = .waiting
        case .whenAsked: phase = .ready
        }
    }
}

extension BackstorySession {
    /// The tags and picture of a file or a Pak's track. A song needs a title and an artist
    /// to be looked up; a file's name is never sent in place of its tags.
    static func describe(_ url: URL, paks: PakRegistry) async -> (PakNowPlaying?, CGImage?) {
        if url.isFileURL {
            let metadata = await TrackMetadata.load(from: url)
            guard let title = metadata.title, let artist = metadata.artist else { return (nil, nil) }
            return (PakNowPlaying(title: title, artist: artist, album: metadata.album), await embeddedArtwork(url))
        }
        guard let pak = paks.pak(for: url), let track = await pak.metadata(for: url),
              !track.title.isEmpty, let artist = track.artist, !artist.isEmpty else { return (nil, nil) }
        let image = await track.artwork.asyncMap { await pak.image(for: $0, size: 96) } ?? nil
        return (PakNowPlaying(title: track.title, artist: artist, album: track.album), image)
    }

    private static func embeddedArtwork(_ url: URL) async -> CGImage? {
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        guard let item = items.first(where: { $0.commonKey == .commonKeyArtwork }),
              let data = try? await item.load(.dataValue),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
        ] as CFDictionary)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
