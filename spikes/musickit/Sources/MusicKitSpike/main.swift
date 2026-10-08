import AppKit
import BitampAppleMusicPak
import BitampPakKit
import MusicKit

// Each step logs what MusicKit returned, to the window and to stdout, so a run from the
// terminal leaves a transcript. `--auto "term"` runs every step in order and quits;
// `--pak "term"` does the same through Bitamp's Apple Music Pak.

@MainActor
final class Spike: NSObject, NSApplicationDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let term = NSTextField(string: "Daft Punk")
    private let logView = NSTextView()
    private var songs: [Song] = []
    private var player: ApplicationMusicPlayer { .shared }
    private let autoTerm: String?
    private let pakTerm: String?

    init(autoTerm: String?, pakTerm: String?) {
        self.autoTerm = autoTerm
        self.pakTerm = pakTerm
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let buttons = [
            ("Authorize", #selector(authorize)), ("Subscription", #selector(subscription)),
            ("Search", #selector(search)), ("Library", #selector(library)),
            ("Play", #selector(play)), ("Pause", #selector(pause)), ("Seek +30s", #selector(seek)),
        ].map { NSButton(title: $0.0, target: self, action: $0.1) }
        let row = NSStackView(views: [term] + buttons)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        let stack = NSStackView(views: [row, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = stack
        window.title = "MusicKit Spike"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        log("bundle \(Bundle.main.bundleIdentifier ?? "none"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("authorization status: \(MusicAuthorization.currentStatus)")
        watchPlayer()
        if let autoTerm { Task { await runAll(autoTerm) } }
        if let pakTerm { Task { await runPak(pakTerm) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(.dateTime.hour().minute().second())) \(line)"
        print(stamped)
        fflush(stdout)
        logView.textStorage?.append(NSAttributedString(
            string: stamped + "\n", attributes: [.font: logView.font!, .foregroundColor: NSColor.textColor]))
        logView.scrollToEndOfDocument(nil)
    }

    /// Logs the player's status and position once a second while they change.
    private func watchPlayer() {
        var last = ""
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let state = self.player.state
                let entry = self.player.queue.currentEntry?.title ?? "-"
                let now = "player \(state.playbackStatus) t=\(String(format: "%.1f", self.player.playbackTime)) entry=\(entry)"
                if now != last { self.log(now) }
                last = now
            }
        }
    }

    private func runAll(_ term: String) async {
        await authorizeAsync()
        await subscriptionAsync()
        await searchAsync(term)
        if songs.isEmpty { await libraryAsync() }
        await playAsync()
        try? await Task.sleep(for: .seconds(10))
        log("auto: pausing at t=\(player.playbackTime)")
        player.pause()
        try? await Task.sleep(for: .seconds(2))
        log("auto: done")
        NSApp.terminate(nil)
    }

    /// Bitamp's Apple Music Pak, as Bitamp drives it: search, load, play, pause, resume,
    /// seek to near the end, and wait for it to say the song ended.
    private func runPak(_ term: String) async {
        let pak = AppleMusicPak()
        log("pak: account \(pak.account), available \(pak.isAvailable)")
        do {
            let tracks = try await pak.search(term)
            log("pak: search \"\(term)\": \(tracks.count) tracks")
            for track in tracks.prefix(5) { log("  \(track.url.absoluteString) \(track.artist ?? "?") – \(track.title) \(track.duration ?? 0)s") }
            guard let track = tracks.first, case .backend(let backend) = try pak.playback(for: track.url) else {
                log("pak: nothing to play"); NSApp.terminate(nil); return
            }
            var ended = false
            backend.onTrackEnd = { ended = true; self.log("pak: onTrackEnd") }
            backend.onLoadFailure = { self.log("pak: onLoadFailure \(self.describe($0))") }
            func report(_ what: String) {
                log("pak: \(what) → state \(backend.state) t=\(String(format: "%.1f", backend.currentTime)) now=\(backend.nowPlaying?.title ?? "-") \(backend.nowPlaying?.duration ?? 0)s")
            }
            try backend.load(track.url)
            report("load")
            backend.play()
            report("play")
            try await Task.sleep(for: .seconds(4))
            report("after 4 s")
            backend.pause()
            try await Task.sleep(for: .seconds(2))
            report("paused 2 s")
            backend.pause()
            try await Task.sleep(for: .seconds(2))
            report("resumed 2 s")
            let duration = backend.nowPlaying?.duration ?? 0
            backend.seek(to: duration - 4)
            report("seek to end - 4")
            for _ in 0..<40 where !ended { try await Task.sleep(for: .milliseconds(250)) }
            report(ended ? "ended" : "NO END after 10 s")

            // A catalog URL from a saved session, looked up fresh (needs a signed build).
            let fresh = AppleMusicPak()
            log("pak: metadata for \(track.url.absoluteString) from a new Pak: \(String(describing: await fresh.metadata(for: track.url)))")
        } catch {
            log("pak failed: \(describe(error))")
        }
        log("pak: done")
        NSApp.terminate(nil)
    }

    @objc private func authorize() { Task { await authorizeAsync() } }
    @objc private func subscription() { Task { await subscriptionAsync() } }
    @objc private func search() { Task { await searchAsync(term.stringValue) } }
    @objc private func play() { Task { await playAsync() } }
    @objc private func pause() { player.pause(); log("pause()") }
    @objc private func seek() { player.playbackTime += 30; log("seek → \(player.playbackTime)") }

    private func authorizeAsync() async {
        log("requesting authorization…")
        let status = await MusicAuthorization.request()
        log("authorization: \(status)")
    }

    private func subscriptionAsync() async {
        do {
            let subscription = try await MusicSubscription.current
            log("subscription: canPlayCatalogContent=\(subscription.canPlayCatalogContent) canBecomeSubscriber=\(subscription.canBecomeSubscriber) hasCloudLibraryEnabled=\(subscription.hasCloudLibraryEnabled)")
        } catch {
            log("subscription failed: \(describe(error))")
        }
    }

    private func searchAsync(_ term: String) async {
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 5
            let response = try await request.response()
            songs = Array(response.songs)
            log("catalog search \"\(term)\": \(songs.count) songs")
            for song in songs { log("  \(song.id) \(song.artistName) – \(song.title) (\(song.duration.map { "\(Int($0))s" } ?? "?"))") }
        } catch {
            log("catalog search failed: \(describe(error))")
        }
    }

    @objc private func library() { Task { await libraryAsync() } }

    private func libraryAsync() async {
            do {
                var request = MusicLibraryRequest<Song>()
                request.limit = 5
                let response = try await request.response()
                songs = Array(response.items)
                log("library: \(songs.count) songs")
                for song in songs { log("  \(song.id) \(song.artistName) – \(song.title)") }
            } catch {
                log("library failed: \(describe(error))")
            }
    }

    private func playAsync() async {
        guard let song = songs.first else {
            log("nothing to play: search or load the library first")
            return
        }
        do {
            player.queue = [song]
            log("prepareToPlay \(song.title)…")
            try await player.prepareToPlay()
            log("play…")
            try await player.play()
            log("play() returned")
        } catch {
            log("play failed: \(describe(error))")
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(error) [\(ns.domain) \(ns.code)] \(ns.userInfo)"
    }
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).map { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : "Daft Punk" }
}
let autoTerm = option("--auto")
let pakTerm = option("--pak")
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Spike(autoTerm: autoTerm, pakTerm: pakTerm)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
