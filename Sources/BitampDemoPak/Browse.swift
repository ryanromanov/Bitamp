import BitampPakSDK
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An album of the demo's tunes, one per composer.
struct DemoAlbum {
    let id: String
    let title: String
    let composer: String
    let year: Int

    static let all = [
        DemoAlbum(id: "beethoven-bits", title: "Beethoven Bits", composer: "Ludwig van Beethoven", year: 1810),
        DemoAlbum(id: "folk-chips", title: "Folk Chips", composer: "Traditional", year: 1700),
    ]

    var tunes: [Tune] { Tune.all.filter { $0.composer == composer } }
}

/// The Media Library's view of the demo: a sidebar of four sections, one of each kind of
/// place, and a cursor on the long list, so a Pak author can see every part of browsing.
extension DemoPak {
    static let bedtime = ["twinkle-twinkle", "frere-jacques", "amazing-grace"]
    /// Tunes per page of "All Tunes", small enough that the list needs a second page.
    static let pageSize = 4

    func browse(_ location: PakBrowseLocation, cursor: String?) async throws -> PakBrowsePage {
        switch location {
        case .root:
            let sections = [("tunes", "All Tunes"), ("composers", "Composers"), ("albums", "Albums"), ("playlists", "Playlists")]
            return PakBrowsePage(shelves: [PakShelfInfo(title: "Demo", items: sections.map {
                .place(PakPlaceInfo(kind: "section", id: $0.0, title: $0.1))
            })])
        case .search(let term):
            guard cursor == nil else { return PakBrowsePage() }
            return PakBrowsePage(shelves: [PakShelfInfo(items: try await search(term).map(PakItemInfo.track))])
        case .place("tunes"):
            let start = cursor.flatMap(Int.init) ?? 0
            let tunes = Array(Tune.all.dropFirst(start).prefix(Self.pageSize))
            let next = start + tunes.count
            return PakBrowsePage(shelves: [PakShelfInfo(items: tunes.map { .track(info($0)) })],
                                 cursor: next < Tune.all.count ? String(next) : nil)
        case .place("composers"):
            return PakBrowsePage(shelves: [PakShelfInfo(items: composers.map {
                .place(PakPlaceInfo(kind: "artist", id: "artist:\($0)", title: $0, artwork: cover("artist-\(slug($0))")))
            })])
        case .place("albums"):
            return PakBrowsePage(shelves: [PakShelfInfo(items: DemoAlbum.all.map(albumPlace))])
        case .place("playlists"):
            return PakBrowsePage(shelves: [PakShelfInfo(items: [
                .place(PakPlaceInfo(kind: "playlist", id: "playlist:bedtime", title: "Bedtime", subtitle: "Bitamp", artwork: cover("bedtime"))),
            ])])
        case .place("playlist:bedtime"):
            let tunes = Self.bedtime.compactMap { id in Tune.all.first { $0.id == id } }
            return PakBrowsePage(header: PakHeaderInfo(title: "Bedtime", subtitle: "Bitamp", detail: "\(tunes.count) songs",
                                                       artwork: cover("bedtime")),
                                 shelves: [PakShelfInfo(items: tunes.map { .track(info($0)) })])
        case .place(let id) where id.hasPrefix("album:"):
            guard let album = DemoAlbum.all.first(where: { "album:\($0.id)" == id }) else { break }
            return PakBrowsePage(header: PakHeaderInfo(title: album.title, subtitle: album.composer,
                                                       detail: "Chiptune · \(album.year) · \(album.tunes.count) songs",
                                                       artwork: cover(album.id)),
                                 shelves: [PakShelfInfo(items: album.tunes.map { .track(info($0)) })])
        case .place(let id) where id.hasPrefix("artist:"):
            let composer = String(id.dropFirst("artist:".count))
            guard composers.contains(composer) else { break }
            return PakBrowsePage(shelves: [
                PakShelfInfo(title: "Albums", items: DemoAlbum.all.filter { $0.composer == composer }.map(albumPlace)),
                PakShelfInfo(title: "Songs", items: Tune.all.filter { $0.composer == composer }.map { .track(info($0)) }),
            ])
        default:
            break
        }
        guard case .place(let id) = location else { return PakBrowsePage() }
        throw PakFailure("Nothing called \(id) here.")
    }

    private var composers: [String] {
        Tune.all.reduce(into: []) { if !$0.contains($1.composer) { $0.append($1.composer) } }
    }

    private func albumPlace(_ album: DemoAlbum) -> PakItemInfo {
        .place(PakPlaceInfo(kind: "album", id: "album:\(album.id)", title: album.title, subtitle: album.composer, artwork: cover(album.id)))
    }

    private func slug(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }

    /// A cover drawn once into the cache: a pixel pattern from the name, so each looks different.
    func cover(_ name: String) -> PakArtworkInfo {
        let file = cache.appendingPathComponent("cover-\(name).png")
        if !FileManager.default.fileExists(atPath: file.path) { Self.drawCover(name, to: file) }
        return .file(file)
    }

    static func drawCover(_ name: String, to file: URL) {
        let size = 8, scale = 16
        guard let context = CGContext(data: nil, width: size * scale, height: size * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var seed = name.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        let hue = Double(next() % 360) / 360
        func color(_ brightness: Double) -> CGColor {
            // Hue to RGB, simply.
            let h = hue * 6, x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Double, Double, Double) = switch Int(h) {
            case 0: (1, x, 0)
            case 1: (x, 1, 0)
            case 2: (0, 1, x)
            case 3: (0, x, 1)
            case 4: (x, 0, 1)
            default: (1, 0, x)
            }
            return CGColor(srgbRed: r * brightness, green: g * brightness, blue: b * brightness, alpha: 1)
        }
        context.setFillColor(color(0.25))
        context.fill(CGRect(x: 0, y: 0, width: size * scale, height: size * scale))
        // A mirrored pattern, like a space invader.
        context.setFillColor(color(0.9))
        for y in 1..<(size - 1) {
            for x in 1..<(size / 2) where next() % 2 == 0 {
                context.fill(CGRect(x: x * scale, y: y * scale, width: scale, height: scale))
                context.fill(CGRect(x: (size - 1 - x) * scale, y: y * scale, width: scale, height: scale))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
