import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Covers for the Media Library, at the sizes it draws them, kept in memory and, when
/// given a folder, on disk, so a cover shown once comes back at once: on the next visit
/// to a page and after a relaunch, without asking the Pak again.
///
/// A cover is found by its Pak, its artwork id and its size, so a Pak's artwork ids must
/// stay the same for the same picture.
@MainActor
final class CoverCache {
    struct Key: Hashable {
        let pak: String
        let artwork: PakArtwork
        let size: Int
    }

    /// Where covers are saved, or nil to keep them in memory only (tests, snapshots).
    let folder: URL?
    private var memory: [Key: CGImage] = [:]
    private static let memoryLimit = 4_000

    nonisolated init(folder: URL? = nil) {
        self.folder = folder
    }

    /// Bitamp's own: in its caches folder, where macOS may clear it.
    static func standard() -> CoverCache {
        CoverCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ryanromanov.Bitamp/Covers", isDirectory: true))
    }

    /// The cover, if it's in memory or on disk. Small enough to read while drawing.
    func cached(_ key: Key) -> CGImage? {
        if let image = memory[key] { return image }
        guard let file = file(for: key), let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        remember(image, key)
        return image
    }

    /// Asks `pak` for the picture, shrinks it to the key's size, and keeps it. Nil if
    /// there's none, or the task was cancelled.
    func load(_ key: Key, from pak: Pak) async -> CGImage? {
        if let image = cached(key) { return image }
        guard !Task.isCancelled else { return nil }
        // Asked for three times larger, then averaged down, for a cleaner small picture.
        guard let picture = await pak.image(for: key.artwork, size: key.size * 3), !Task.isCancelled else { return nil }
        let image = Self.shrink(picture, to: key.size)
        remember(image, key)
        if let file = file(for: key) {
            Task.detached(priority: .utility) { Self.write(image, to: file) }
        }
        return image
    }

    private func remember(_ image: CGImage, _ key: Key) {
        // Covers are a few KB each; past the limit, start over rather than track use.
        if memory.count >= Self.memoryLimit { memory = [:] }
        memory[key] = image
    }

    /// `<folder>/<pak>/<hash of the artwork id>-<size>.png`.
    private func file(for key: Key) -> URL? {
        guard let folder else { return nil }
        let hash = SHA256.hash(data: Data(key.artwork.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key.pak, isDirectory: true).appendingPathComponent("\(hash)-\(key.size).png")
    }

    nonisolated private static func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// `image` at `size` pixels square, each pixel the average of what it covers.
    static func shrink(_ image: CGImage, to size: Int) -> CGImage {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage() ?? image
    }
}
