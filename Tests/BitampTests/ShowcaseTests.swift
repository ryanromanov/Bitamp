import AppKit
import AVFoundation
import Foundation
import Testing
@testable import BitampKit

/// Renders the README's screenshots and the repository's social preview from the views
/// themselves, mid-song with a made-up playlist, so they stay pixel-sharp and show nothing
/// of anyone's own library. Off by default; `scripts/screenshots.sh` runs it into docs/images.
///
/// Each image is scaled up by a whole number with nearest-neighbor sampling. The README shows
/// them at half their pixel width, so Retina screens get every pixel and others an exact 2:1
/// reduction.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_SHOWCASE"] != nil))
struct ShowcaseTests {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BITAMP_SHOWCASE"] ?? "/tmp")

    /// Invented artists and songs.
    static let playlist: [(artist: String, title: String, seconds: Double)] = [
        ("Pixel Harbor", "Neon Tide", 222),
        ("The Low Bits", "Dial-Up Sunrise", 245),
        ("Mira Vance", "Cassette Hearts", 198),
        ("Signal Lost", "Analog Weather", 301),
        ("Kilobyte Club", "Midnight Modem", 176),
        ("Vector Bloom", "Paper Planets", 267),
        ("Old Stereo", "Summer on Repeat", 214),
    ]
    static let playing = 1
    static let elapsed = 74.0

    /// A controller mid-way through the second song, with a gentle smile on the equalizer
    /// and a chord through the visualizer.
    func stagedController() -> PlaybackController {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampShowcase-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        let urls = Self.playlist.map { URL(fileURLWithPath: "/showcase/\($0.artist) - \($0.title).mp3") }
        for (url, song) in zip(urls, Self.playlist) {
            controller.info.seed(TrackMetadata(title: song.title, artist: song.artist, duration: song.seconds, kbps: 320), for: url)
        }
        controller.setQueueItems(urls, current: Self.playing)
        let song = Self.playlist[Self.playing]
        controller.engine.stage(PlayerEngine.Track(url: urls[Self.playing], title: song.title, artist: song.artist,
                                                   duration: song.seconds, sampleRate: 44_100, channels: 2, kbps: 320),
                                at: Self.elapsed)
        var equalizer = EqualizerSettings()
        equalizer.bands = [4.5, 3, 1, -1, -2, -1.5, 0.5, 2.5, 4, 5]
        controller.equalizer = equalizer

        // A loud chord, then a softer one, so the bars have fallen a little below their peaks.
        let analyzer = controller.engine.analyzer
        for (loudness, frames) in [(Float(0.5), 3), (0.22, 5)] {
            analyzer.process(Self.chord(loudness))
            for _ in 0..<frames { analyzer.advance() }
        }
        return controller
    }

    /// A tenth of a second of a bass note, a chord with overtones, and hiss to fill in
    /// between them as real music does.
    static func chord(_ loudness: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 4_096
        var noise = SplitMix64(seed: 7)
        let notes: [(Double, Float)] = [(55, 1), (110, 0.8), (220, 0.6), (277.2, 0.5), (329.6, 0.5), (440, 0.4),
                                        (880, 0.25), (1_318, 0.2), (2_637, 0.12), (5_274, 0.07), (9_000, 0.04)]
        for i in 0..<4_096 {
            let t = Double(i) / 44_100
            var sample = notes.reduce(Float(0)) { $0 + $1.1 * Float(sin(2 * .pi * $1.0 * t)) }
            sample += Float(Double(noise.next() % 1_000) / 1_000 - 0.5) * 0.6
            for channel in 0..<2 { buffer.floatChannelData![channel][i] = loudness * sample / 4 }
        }
        return buffer
    }

    /// The view as an image, one pixel per skin pixel (or a whole multiple of that).
    func image(_ view: SkinnedView) throws -> CGImage {
        view.drawsAsActive = true
        view.tick()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// A window placed in a layout, in skin pixels from the top left.
    struct Placed {
        var image: CGImage
        var size: CGSize
        var origin: CGPoint
    }

    /// Draws `windows` scaled by `factor`, with a shared soft shadow, on `background` (or
    /// transparent), centered in `canvas` if given, else with a margin around them.
    func compose(_ windows: [Placed], factor: CGFloat, background: NSColor? = nil, canvas: CGSize? = nil) throws -> Data {
        let bounds = windows.map { CGRect(origin: $0.origin, size: $0.size) }.reduce(CGRect.null) { $0.union($1) }
        let margin = 16 * factor
        let size = canvas ?? CGSize(width: bounds.width * factor + 2 * margin, height: bounds.height * factor + 2 * margin)
        let offset = CGPoint(x: ((size.width - bounds.width * factor) / 2).rounded(), y: ((size.height - bounds.height * factor) / 2).rounded())
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        context.interpolationQuality = .none
        context.setShadow(offset: CGSize(width: 0, height: -3 * factor), blur: 10 * factor,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for window in windows {
            let x = offset.x + (window.origin.x - bounds.minX) * factor
            let top = offset.y + (window.origin.y - bounds.minY) * factor
            context.draw(window.image, in: CGRect(x: x, y: size.height - top - window.size.height * factor,
                                                  width: window.size.width * factor, height: window.size.height * factor))
        }
        context.endTransparencyLayer()
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The main window with the equalizer and a short playlist docked under it.
    func stack(_ skin: Skin, playlistRows: CGFloat = 1) throws -> [Placed] {
        let controller = stagedController()
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampShowcase-\(UUID().uuidString)")!)
        let main = MainView(controller: controller, preferences: preferences, skin: skin)
        main.drawsPanelsAsOpen = true
        let equalizer = EqualizerView(controller: controller, skin: skin, scale: 1)
        let playlist = PlaylistView(controller: controller, preferences: preferences, skin: skin)
        playlist.setFrameSize(NSSize(width: PlaylistLayout.width * playlist.scale,
                                     height: (PlaylistLayout.minHeight + playlistRows * PlaylistLayout.heightStep) * playlist.scale))
        var placed: [Placed] = []
        var y: CGFloat = 0
        for view in [main, equalizer, playlist] as [SkinnedView] {
            placed.append(Placed(image: try image(view), size: view.pixelSize, origin: CGPoint(x: 0, y: y)))
            y += view.pixelSize.height
        }
        return placed
    }

    @Test func screenshots() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The README's main picture: the default skin, all three windows.
        try compose(stack(DefaultSkin()), factor: 4).write(to: folder.appendingPathComponent("bitamp.png"))

        // The other built-in skins, all three windows each, for a row under it.
        for (name, skin) in [("millennium", DefaultSkin(theme: .millennium)), ("orb", DefaultSkin(theme: .orb))] {
            try compose(stack(skin, playlistRows: 0), factor: 2).write(to: folder.appendingPathComponent("skin-\(name).png"))
        }

        // The social preview GitHub shows for links to the repository: 1280 × 640.
        let main = try stack(DefaultSkin(theme: .orb), playlistRows: 0)
        try compose(Array(main.prefix(1)), factor: 3, background: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.27, alpha: 1),
                    canvas: CGSize(width: 1_280, height: 640))
            .write(to: folder.appendingPathComponent("social-preview.png"))
    }
}
