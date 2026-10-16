import AppKit
import BitampAppleMusicPak
import BitampPakKit

/// `--browse "term"`: walks the Apple Music Pak's browsing as the Media Library will:
/// the sidebar, each section, the first place in each, a search, and some artwork,
/// logging what came back and how long it took. The first covers of each section go on a
/// sheet in `BITAMP_ART_OUT` (default: the temporary folder), shrunk to 44 px.
///
/// The log and sheet show the listener's own library, so keep them out of commits.
@MainActor
struct BrowseProbe {
    let log: (String) -> Void
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BITAMP_ART_OUT"]
        ?? NSTemporaryDirectory())
    let pak = AppleMusicPak()

    func run(_ term: String) async {
        var covers: [(String, CGImage?)] = []
        /// One place of each kind, and a track from each kind of page, for a fresh Pak
        /// to look up with nothing cached, as after a relaunch.
        var saved: [String: String] = [:]
        var savedTracks: [String: URL] = [:]
        func save(_ page: PakPage, from label: String) {
            for place in page.shelves.flatMap({ $0.items.compactMap(\.place) }) where place.kind != .section {
                let kind = String(place.id.split(separator: "/").first ?? "")
                let key = place.id.contains("playlist/p.") && !place.id.hasPrefix("library") ? "\(kind) (p.)"
                    : place.id.contains("/p.") ? "\(kind) (p.)" : kind
                if saved[key] == nil { saved[key] = place.id }
            }
            if let track = page.tracks.first, savedTracks[label] == nil { savedTracks[label] = track.url }
        }
        guard let root = await timed("root", { try await pak.browse(.root, after: nil) }) else { return }
        for shelf in root.shelves {
            log("browse: sidebar \(shelf.title ?? "-"): \(shelf.items.compactMap(\.place?.title).joined(separator: ", "))")
        }
        for section in root.shelves.flatMap({ $0.items.compactMap(\.place) }) {
            guard let page = await timed(section.title, { try await pak.browse(.place(section.id), after: nil) }) else { continue }
            describe(page)
            save(page, from: section.title)
            if let cursor = page.cursor {
                _ = await timed("\(section.title) after \(cursor)", { try await pak.browse(.place(section.id), after: cursor) })
            }
            let places = page.shelves.flatMap { $0.items.compactMap(\.place) }
            if let first = places.first,
               let opened = await timed("  open \(first.kind) “\(first.title)”", { try await pak.browse(.place(first.id), after: nil) }) {
                describe(opened, indent: "    ")
                save(opened, from: "\(section.title) ▸ \(first.kind)")
            }
            if section.id == "section/charts" {
                for playlist in places.filter({ $0.kind == .playlist }).prefix(4) {
                    _ = await timed("  big playlist “\(playlist.title)”", { try await pak.browse(.place(playlist.id), after: nil) })
                }
            }
            for place in places.prefix(4) {
                covers.append(("\(section.title): \(place.title)", await cover(place.artwork)))
            }
            for track in page.tracks.prefix(4) {
                covers.append(("\(section.title): \(track.title)", await cover(track.artwork)))
            }
        }
        if let playlist = root.shelves.flatMap({ $0.items.compactMap(\.place) }).first(where: { $0.id == "section/playlists" }),
           let page = try? await pak.browse(.place(playlist.id), after: nil),
           let first = page.shelves.first?.items.first?.place {
            let start = Date()
            let tracks = (try? await pak.allTracks(at: .place(first.id))) ?? []
            log("browse: allTracks “\(first.title)”: \(tracks.count) tracks in \(ms(start)) ms")
        }
        if let found = await timed("search “\(term)”", { try await pak.browse(.search(term), after: nil) }) {
            describe(found)
            save(found, from: "search")
        }

        let fresh = AppleMusicPak()
        for (kind, id) in saved.sorted(by: { $0.key < $1.key }) {
            _ = await timed("fresh Pak opens \(kind)", { try await fresh.browse(.place(id), after: nil) })
        }
        for (label, url) in savedTracks.sorted(by: { $0.key < $1.key }) {
            let start = Date()
            let track = await fresh.metadata(for: url)
            log("browse: fresh Pak metadata for a track from \(label) (\(url.host ?? "?")): \(track == nil ? "NONE" : "ok") in \(ms(start)) ms")
        }
        do {
            let url = folder.appendingPathComponent("browse-covers.png")
            try sheet(covers).write(to: url)
            log("browse: covers at \(url.path)")
        } catch {
            log("browse: couldn't write the covers: \(error)")
        }
    }

    private func timed(_ what: String, _ body: () async throws -> PakPage) async -> PakPage? {
        let start = Date()
        do {
            let page = try await body()
            log("browse: \(what): \(page.shelves.count) shelves, \(page.shelves.map(\.items.count).reduce(0, +)) items"
                + "\(page.cursor.map { ", more after \($0)" } ?? "") in \(ms(start)) ms")
            return page
        } catch {
            log("browse: \(what) failed after \(ms(start)) ms: \(error)")
            return nil
        }
    }

    private func describe(_ page: PakPage, indent: String = "  ") {
        if let header = page.header {
            log("browse: \(indent)header “\(header.title)” / \(header.subtitle ?? "-") / \(header.detail ?? "-") / art \(header.artwork != nil)")
        }
        for shelf in page.shelves {
            let names = shelf.items.prefix(3).map { item -> String in
                switch item {
                case .track(let track): return "♪ \(track.title) <\(track.url.absoluteString)>"
                case .place(let place): return "[\(place.kind)] \(place.title) <\(place.id)>"
                }
            }
            log("browse: \(indent)\(shelf.title ?? "(list)"): \(shelf.items.count): \(names.joined(separator: "; "))")
        }
    }

    private func cover(_ artwork: PakArtwork?) async -> CGImage? {
        guard let artwork else { return nil }
        let start = Date()
        let image = await pak.image(for: artwork, size: 176)
        log("browse: art \(artwork.id.prefix(24)) → \(image.map { "\($0.width)×\($0.height)" } ?? "none") in \(ms(start)) ms")
        return image
    }

    private func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// The covers at 44 px, shown 4× nearest-neighbor, eight to a row.
    private func sheet(_ covers: [(String, CGImage?)]) throws -> Data {
        let cell = 44 * 4 + 8, columns = 8
        let rows = max(1, (covers.count + columns - 1) / columns)
        let context = CGContext(data: nil, width: columns * cell + 8, height: rows * cell + 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .none
        for (index, (_, image)) in covers.enumerated() {
            let x = 8 + (index % columns) * cell, y = context.height - (index / columns + 1) * cell
            if let image {
                context.draw(ArtProbe.shrink(image), in: CGRect(x: x, y: y, width: 176, height: 176))
            } else {
                context.setFillColor(CGColor(gray: 0.25, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 176, height: 176))
            }
        }
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }
}
