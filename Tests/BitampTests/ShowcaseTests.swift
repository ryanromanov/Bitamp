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

        // The Expansion Paks window with the demo Pak inserted, for the README's Paks section.
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampShowcase-\(UUID().uuidString)")!)
        let paks = PakRegistry([ShowcasePak()], preferences: preferences)
        let pakView = PakView(controller: PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: paks),
                              skin: DefaultSkin(), scale: 1)
        try compose([Placed(image: try image(pakView), size: pakView.pixelSize, origin: .zero)], factor: 4)
            .write(to: folder.appendingPathComponent("expansion-paks.png"))

        // The social preview GitHub shows for links to the repository: 1280 × 640.
        let main = try stack(DefaultSkin(theme: .orb), playlistRows: 0)
        try compose(Array(main.prefix(1)), factor: 3, background: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.27, alpha: 1),
                    canvas: CGSize(width: 1_280, height: 640))
            .write(to: folder.appendingPathComponent("social-preview.png"))
    }
}

extension ShowcaseTests {
    /// The Media Library for the README: invented albums with patterned covers, in the
    /// default skin, at 2× like the main picture's 4× in the README's units.
    @Test func library() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampShowcase-\(UUID().uuidString)")!)
        let pak = ShowcaseLibraryPak()
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences, paks: PakRegistry([pak], preferences: preferences))
        let view = MediaLibraryView(controller: controller, skin: DefaultSkin(), scale: 1)
        view.show(pak)
        for _ in 0..<200 where view.shown?.items.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        view.moveFocus(to: 0)
        // Draw once so the covers in view are asked for, then let them arrive.
        _ = try image(view)
        try await Task.sleep(for: .milliseconds(200))
        try compose([Placed(image: try image(view), size: view.pixelSize, origin: .zero)], factor: 2)
            .write(to: folder.appendingPathComponent("media-library.png"))
    }
}

/// Invented albums for the Media Library picture.
@MainActor
private final class ShowcaseLibraryPak: Pak {
    let id = "applemusic"
    let name = "Apple Music"
    let schemes: Set<String> = ["showcase"]
    let isAvailable = true
    let account = PakAccount.connected(name: nil)
    var canBrowse: Bool { true }

    static let albums = [
        ("Analog Weather", "Signal Lost"), ("Neon Tide", "Pixel Harbor"), ("Dial-Up Sunrise", "The Low Bits"),
        ("Cassette Hearts", "Mira Vance"), ("Midnight Modem", "Kilobyte Club"), ("Paper Planets", "Vector Bloom"),
        ("Summer on Repeat", "Old Stereo"), ("Harbor Lights", "Pixel Harbor"), ("Static Garden", "Signal Lost"),
        ("Low Tide FM", "The Low Bits"), ("Glass Arcade", "Mira Vance"), ("Afterglow Drive", "Vector Bloom"),
        ("Floppy Love", "Kilobyte Club"), ("Backseat Radio", "Old Stereo"), ("Chrome Orchard", "Vector Bloom"),
        ("Saturday Sprites", "The Low Bits"), ("Night Bus", "Mira Vance"), ("Tape Hiss", "Old Stereo"),
    ]

    func browse(_ location: PakLocation, after cursor: String?) async throws -> PakPage {
        switch location {
        case .root:
            let library = ["Recently Added", "Albums", "Artists", "Songs", "Playlists"]
            let catalog = ["For You", "Recently Played", "Top Charts"]
            func sections(_ titles: [String]) -> [PakItem] {
                titles.map { .place(PakPlace(id: "section/\($0)", kind: .section, title: $0)) }
            }
            return PakPage(shelves: [PakShelf(title: "Library", items: sections(library)),
                                     PakShelf(title: "Apple Music", items: sections(catalog))])
        default:
            return PakPage(shelves: [PakShelf(items: Self.albums.enumerated().map { index, album in
                .place(PakPlace(id: "album/\(index)", kind: .album, title: album.0, subtitle: album.1,
                                artwork: PakArtwork("\(index * 7 + 3)")))
            })])
        }
    }

    func image(for artwork: PakArtwork, size: Int) async -> CGImage? {
        UInt64(artwork.id).map { showcaseCover($0, size: size) }
    }

    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}

/// An abstract cover, the same design at any size.
func showcaseCover(_ seed: UInt64, size: Int) -> CGImage {
    var random = SplitMix64(seed: seed &* 2654435761)
    func unit() -> CGFloat { CGFloat(random.next() % 10_000) / 10_000 }
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    let s = CGFloat(size)
    let hue = unit()
    func color(_ h: CGFloat, _ sat: CGFloat, _ bright: CGFloat) -> CGColor {
        NSColor(hue: (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1),
                saturation: sat, brightness: bright, alpha: 1).cgColor
    }
    let top = color(hue, 0.7, 0.35), bottom = color(hue + 0.12, 0.8, 0.85)
    let accent = color(hue + 0.5, 0.75, 1), light = color(hue + 0.08, 0.25, 1)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bottom, top] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: s), options: [])

    switch seed % 6 {
    case 0: // sun over stripes
        context.setFillColor(accent)
        context.fillEllipse(in: CGRect(x: s * 0.2, y: s * 0.25, width: s * 0.6, height: s * 0.6))
        context.setFillColor(bottom)
        for i in 0..<5 {
            let y = s * (0.28 + CGFloat(i) * 0.08)
            context.fill(CGRect(x: 0, y: y, width: s, height: s * 0.012 * CGFloat(5 - i) + 1))
        }
    case 1: // rings
        for i in (0..<6).reversed() {
            context.setFillColor(i % 2 == 0 ? accent : top)
            let r = s * 0.08 * CGFloat(i + 1)
            context.fillEllipse(in: CGRect(x: s * 0.5 - r, y: s * 0.5 - r, width: r * 2, height: r * 2))
        }
    case 2: // mountains
        for (i, shade) in [light, accent, top].enumerated() {
            context.setFillColor(shade)
            let base = s * (0.1 + CGFloat(i) * 0.12) - s * 0.2
            context.beginPath()
            context.move(to: CGPoint(x: -s * 0.1, y: 0))
            context.addLine(to: CGPoint(x: s * unit(), y: s * 0.75 - base))
            context.addLine(to: CGPoint(x: s * 1.1, y: 0))
            context.fillPath()
        }
    case 3: // diagonal stripes
        context.setFillColor(accent)
        for i in stride(from: -4, to: 8, by: 2) {
            let x = s * CGFloat(i) * 0.12
            context.beginPath()
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + s * 0.12, y: 0))
            context.addLine(to: CGPoint(x: x + s * 0.72, y: s))
            context.addLine(to: CGPoint(x: x + s * 0.6, y: s))
            context.fillPath()
        }
    case 4: // bubbles
        for _ in 0..<7 {
            context.setFillColor((unit() > 0.5 ? accent : light).copy(alpha: 0.75)!)
            let r = s * (0.08 + unit() * 0.2)
            context.fillEllipse(in: CGRect(x: s * unit() - r, y: s * unit() - r, width: r * 2, height: r * 2))
        }
    default: // checker floor and a moon
        context.setFillColor(light)
        context.fillEllipse(in: CGRect(x: s * 0.55, y: s * 0.58, width: s * 0.28, height: s * 0.28))
        let cells = 6
        for row in 0..<3 {
            for column in 0..<cells where (row + column) % 2 == 0 {
                context.setFillColor(accent)
                let w = s / CGFloat(cells)
                context.fill(CGRect(x: CGFloat(column) * w, y: CGFloat(row) * w * 0.7, width: w, height: w * 0.7))
            }
        }
    }
    return context.makeImage()!
}

/// Stands in for the demo Pak in the Expansion Paks picture, without running its program.
@MainActor
private final class ShowcasePak: Pak {
    let id = "demo"
    let name = "Demo"
    let schemes: Set<String> = ["bitpak-demo"]
    let isAvailable = true
    let account = PakAccount.connected(name: nil)
    func connect() async throws {}
    func disconnect() {}
    func search(_ term: String) async throws -> [PakTrack] { [] }
    func metadata(for url: URL) async -> PakTrack? { nil }
    func playback(for url: URL) throws -> PakPlayback { throw CocoaError(.featureUnsupported) }
}
