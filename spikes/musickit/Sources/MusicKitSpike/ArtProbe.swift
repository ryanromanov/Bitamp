import AppKit
import MusicKit
import SwiftUI

/// `--art "term"`: how Bitamp could get artwork for a skinned Media Library. For library
/// albums, playlists and songs, and catalog albums, it logs what `Artwork` offers and tries,
/// in order: loading an http(s) URL; capturing `ArtworkImage` from a window that's never
/// shown, then from one ordered in off screen; and last, a tile in the artwork's
/// background color. Each result is shrunk to 44 px (a skinned grid cover) and laid out
/// on a contact sheet, written to `BITAMP_ART_OUT` (default: the temporary folder).
///
/// The sheet shows the listener's own library, so keep it out of commits.
@MainActor
struct ArtProbe {
    let log: (String) -> Void
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BITAMP_ART_OUT"]
        ?? NSTemporaryDirectory())

    struct Item {
        let kind: String
        let title: String
        let artwork: Artwork?
    }

    struct Result {
        let item: Item
        let rung: String
        let milliseconds: Int
        let image: CGImage?
    }

    static let sourceSize = 264
    static let coverSize = 44

    func run(_ term: String) async {
        let items = await fetch(term)
        log("art: \(items.count) items")
        var results: [Result] = []
        for item in items {
            results.append(await probe(item))
        }
        let rungs = Dictionary(grouping: results, by: { "\($0.item.kind): \($0.rung)" }).mapValues(\.count)
        for (key, count) in rungs.sorted(by: { $0.key < $1.key }) { log("art: summary \(key) ×\(count)") }
        do {
            let url = folder.appendingPathComponent("art-probe.png")
            try sheet(results).write(to: url)
            log("art: sheet at \(url.path)")
        } catch {
            log("art: couldn't write the sheet: \(error)")
        }
    }

    // MARK: - Items

    private func fetch(_ term: String) async -> [Item] {
        var items: [Item] = []
        do {
            var request = MusicLibraryRequest<Album>()
            request.limit = 8
            items += try await request.response().items.map { Item(kind: "library album", title: $0.title, artwork: $0.artwork) }
        } catch { log("art: library albums failed: \(error)") }
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 6
            items += try await request.response().items.map { Item(kind: "library playlist", title: $0.name, artwork: $0.artwork) }
        } catch { log("art: library playlists failed: \(error)") }
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = 6
            items += try await request.response().items.map { Item(kind: "library song", title: $0.title, artwork: $0.artwork) }
        } catch { log("art: library songs failed: \(error)") }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
            request.limit = 6
            items += try await request.response().albums.map { Item(kind: "catalog album", title: $0.title, artwork: $0.artwork) }
        } catch { log("art: catalog albums failed (expected without a team signature): \(error)") }
        return items
    }

    // MARK: - Probing one item

    private func probe(_ item: Item) async -> Result {
        let start = Date()
        func done(_ rung: String, _ image: CGImage?) -> Result {
            let result = Result(item: item, rung: rung, milliseconds: Int(Date().timeIntervalSince(start) * 1000), image: image)
            log("art:   → \(rung) in \(result.milliseconds) ms")
            return result
        }
        guard let artwork = item.artwork else {
            log("art: [\(item.kind)] \(item.title): no artwork")
            return done("none", nil)
        }
        let url = artwork.url(width: Self.sourceSize, height: Self.sourceSize)
        log("art: [\(item.kind)] \(item.title): url \(url.map { "\($0.scheme ?? "?")://…" } ?? "nil"), "
            + "max \(artwork.maximumWidth)×\(artwork.maximumHeight), "
            + "background \(describe(artwork.backgroundColor)), text \(describe(artwork.primaryTextColor))")

        if let url, url.scheme == "https" || url.scheme == "http" {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    return done("https", image)
                }
                log("art:   https data wasn't an image")
            } catch {
                log("art:   https failed: \(error)")
            }
        }
        if let image = await capture(artwork, orderedIn: false) { return done("ArtworkImage (never shown)", image) }
        if let image = await capture(artwork, orderedIn: true) { return done("ArtworkImage (off screen)", image) }
        if let color = artwork.backgroundColor { return done("background color", tile(color)) }
        return done("none", nil)
    }

    /// `ArtworkImage` in a window, captured once its pixels stop being one flat color
    /// (the placeholder), or nil after 3 s.
    private func capture(_ artwork: Artwork, orderedIn: Bool) async -> CGImage? {
        let size = CGFloat(Self.sourceSize) / 2 // points; captured at 2×
        let host = NSHostingView(rootView: ArtworkImage(artwork, width: size, height: size))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size, height: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        if orderedIn { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Self.sourceSize, pixelsHigh: Self.sourceSize,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            if let image = rep.cgImage, !isFlat(rep) { return image }
        }
        return nil
    }

    /// True when a grid of sampled pixels is all (nearly) one color, or all clear.
    private func isFlat(_ rep: NSBitmapImageRep) -> Bool {
        var colors: [NSColor] = []
        for y in stride(from: 4, to: rep.pixelsHigh, by: rep.pixelsHigh / 8) {
            for x in stride(from: 4, to: rep.pixelsWide, by: rep.pixelsWide / 8) {
                if let color = rep.colorAt(x: x, y: y) { colors.append(color) }
            }
        }
        guard let first = colors.first else { return true }
        return colors.allSatisfy { color in
            abs(color.redComponent - first.redComponent) + abs(color.greenComponent - first.greenComponent)
                + abs(color.blueComponent - first.blueComponent) + abs(color.alphaComponent - first.alphaComponent) < 0.06
        }
    }

    private func tile(_ color: CGColor) -> CGImage {
        let context = Self.context(Self.coverSize, Self.coverSize)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: Self.coverSize, height: Self.coverSize))
        return context.makeImage()!
    }

    private func describe(_ color: CGColor?) -> String {
        guard let color, let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // MARK: - The contact sheet

    private static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// The image shrunk to a skinned cover, averaging rather than picking pixels.
    static func shrink(_ image: CGImage) -> CGImage {
        let context = context(coverSize, coverSize)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: coverSize, height: coverSize))
        return context.makeImage()!
    }

    /// One row per item: the source smooth at 176 px, the 44 px cover at 4× nearest-neighbor,
    /// and what worked.
    private func sheet(_ results: [Result]) throws -> Data {
        let row = 196, width = 820
        let context = Self.context(width, max(1, results.count) * row + 20)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: context.height))
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.current = nil }
        for (index, result) in results.enumerated() {
            let top = context.height - 10 - (index + 1) * row + 10
            if let image = result.image {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 10, y: top, width: 176, height: 176))
                context.interpolationQuality = .none
                context.draw(Self.shrink(image), in: CGRect(x: 200, y: top, width: 176, height: 176))
            }
            let text = "\(result.item.kind)\n\(result.item.title)\n\(result.rung)\n\(result.milliseconds) ms"
            (text as NSString).draw(in: NSRect(x: 392, y: top, width: width - 400, height: 176), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white,
            ])
        }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }
}
