import AppKit
import BitampPakKit
import MusicKit
import SwiftUI

/// MusicKit artwork under keys Bitamp can hold on to. Catalog art has https addresses;
/// library art comes as `musicKit://` addresses that only `ArtworkImage` can draw, so it
/// is drawn in a window that's never shown and captured. Captures run one at a time.
@MainActor
final class ArtworkStore {
    static let prefix = "applemusic-art:"
    private var artworks: [String: Artwork] = [:]
    /// Keys by the artwork's address, so the same picture gets the same key.
    private var keys: [String: String] = [:]
    private var capturing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func reference(_ artwork: Artwork?) -> PakArtwork? {
        guard let artwork else { return nil }
        let address = artwork.url(width: 64, height: 64)?.absoluteString
        if let address, let key = keys[address] { return PakArtwork(key) }
        let key = Self.prefix + String(artworks.count)
        artworks[key] = artwork
        if let address { keys[address] = key }
        return PakArtwork(key)
    }

    func image(for reference: PakArtwork, size: Int) async -> CGImage? {
        guard let artwork = artworks[reference.id] else { return await reference.download() }
        if let url = artwork.url(width: size, height: size), ["http", "https"].contains(url.scheme?.lowercased()) {
            return await PakArtwork(url: url).download().map(Self.square)
        }
        await takeTurn()
        defer { endTurn() }
        return await capture(artwork, size: size).map(Self.square)
    }

    private func takeTurn() async {
        if !capturing {
            capturing = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            capturing = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// `ArtworkImage` drawn at `size` pixels, once it has loaded: when some of its pixels
    /// show and they aren't all one color, or after 3 s, whatever it shows then.
    private func capture(_ artwork: Artwork, size: Int) async -> CGImage? {
        let points = CGFloat(size) / 2
        let host = NSHostingView(rootView: ArtworkImage(artwork, width: points, height: points))
        host.frame = NSRect(x: 0, y: 0, width: points, height: points)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var last: CGImage?
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return nil }
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            switch Self.look(rep) {
            case .blank: continue
            case .flat: last = rep.cgImage
            case .picture: return rep.cgImage
            }
        }
        return last
    }

    private enum Look {
        case blank, flat, picture
    }

    /// Whether a grid of sampled pixels is all clear, all one color, or a picture.
    private static func look(_ rep: NSBitmapImageRep) -> Look {
        var colors: [NSColor] = []
        let step = max(1, rep.pixelsWide / 8)
        for y in stride(from: step / 2, to: rep.pixelsHigh, by: step) {
            for x in stride(from: step / 2, to: rep.pixelsWide, by: step) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { colors.append(color) }
            }
        }
        guard let first = colors.first else { return .blank }
        let flat = colors.allSatisfy {
            abs($0.redComponent - first.redComponent) + abs($0.greenComponent - first.greenComponent)
                + abs($0.blueComponent - first.blueComponent) < 0.06
        }
        return flat ? .flat : .picture
    }

    /// The middle square of `image`, after trimming clear bands around it (`ArtworkImage`
    /// fits wide art inside its frame).
    static func square(_ image: CGImage) -> CGImage {
        var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if let opaque = opaqueBounds(image) { bounds = opaque }
        let side = min(bounds.width, bounds.height)
        let crop = CGRect(x: (bounds.midX - side / 2).rounded(.down), y: (bounds.midY - side / 2).rounded(.down),
                          width: side, height: side)
        return image.cropping(to: crop) ?? image
    }

    /// The smallest rectangle (top-left origin) holding every pixel that isn't nearly clear.
    private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let (w, h) = (image.width, image.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        // The context's rows run from the top of the image.
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
