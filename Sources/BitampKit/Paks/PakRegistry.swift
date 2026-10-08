@_exported import BitampPakKit
import Foundation

/// The Expansion Paks Bitamp knows about, which are inserted, and which one plays a given
/// queue item. An ejected Pak keeps its tracks in the playlist but doesn't play them.
@MainActor
final class PakRegistry {
    private(set) var paks: [Pak] = []
    private let preferences: Preferences?
    private var ejected: Set<String>

    init(_ paks: [Pak] = [], preferences: Preferences? = nil) {
        self.preferences = preferences
        ejected = preferences?.ejectedPaks ?? []
        paks.forEach(register)
    }

    func register(_ pak: Pak) {
        precondition(!paks.contains { $0.id == pak.id }, "two Paks with the id \(pak.id)")
        paks.append(pak)
    }

    func unregister(_ pak: Pak) {
        paks.removeAll { $0 === pak }
    }

    func isInserted(_ pak: Pak) -> Bool {
        !ejected.contains(pak.id)
    }

    func setInserted(_ inserted: Bool, _ pak: Pak) {
        if inserted { ejected.remove(pak.id) } else { ejected.insert(pak.id) }
        preferences?.ejectedPaks = ejected
    }

    /// The URL schemes of the Paks that can run on this Mac, inserted or not, so an
    /// ejected Pak's tracks stay in playlists.
    var schemes: Set<String> {
        paks.filter(\.isAvailable).reduce(into: []) { $0.formUnion($1.schemes) }
    }

    /// The Pak whose track `url` is, if it can run here, inserted or not.
    func owner(of url: URL) -> Pak? {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased() else { return nil }
        return paks.first { $0.isAvailable && $0.schemes.contains(scheme) }
    }

    /// The Pak that plays `url`: its owner, if inserted.
    func pak(for url: URL) -> Pak? {
        owner(of: url).flatMap { isInserted($0) ? $0 : nil }
    }
}
