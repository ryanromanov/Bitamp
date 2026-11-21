import BitampPakKit
import BitampPakProtocol
import Foundation
import Testing
@testable import BitampAppleMusicHelper
@testable import BitampKit

@MainActor @Suite struct AppleMusicHelperTests {
    @Test func aSongIsItsURLWithoutTheScheme() {
        let library = URL(string: "applemusic://library/song/123")!
        #expect(AppleMusicProvider.id(library) == "library/song/123")
        #expect(AppleMusicProvider.url("library/song/123") == library)
        let catalog = URL(string: "applemusic://catalog/song/i.abc")!
        #expect(AppleMusicProvider.url(AppleMusicProvider.id(catalog)) == catalog)
    }

    @Test func aTrackSurvivesTheTripThroughBitampsURLs() {
        // The Pak's id becomes bitpak-apple-music://track/library/song/123, and comes back as it was.
        let id = "library/song/123"
        let url = ExternalPak.trackURL(id, pak: "apple-music")
        #expect(url.absoluteString == "bitpak-apple-music://track/library/song/123")
        #expect(ExternalPak.trackID(url, pak: "apple-music") == id)
    }

    @Test func aPageKeepsItsHeaderShelvesAndCoversAsKeys() {
        let album = PakPlace(id: "library-album/9", kind: .album, title: "Discovery", subtitle: "Daft Punk",
                             artwork: PakArtwork("applemusic-art:library-album/9"))
        let song = PakTrack(url: URL(string: "applemusic://catalog/song/5")!, title: "Aerodynamic", artist: "Daft Punk",
                            album: "Discovery", duration: 212, artwork: PakArtwork("applemusic-art:applemusic://catalog/song/5"))
        let page = PakPage(header: PakHeader(title: "Discovery", detail: "2 songs", artwork: PakArtwork("applemusic-art:x")),
                           shelves: [PakShelf(title: "Songs", items: [.track(song), .place(album)])], cursor: "100")
        let wire = AppleMusicProvider.page(page)

        #expect(wire.cursor == "100" && wire.header?.title == "Discovery" && wire.header?.artwork?.id == "applemusic-art:x")
        guard case .track(let track) = wire.shelves[0].items[0], case .place(let place) = wire.shelves[0].items[1] else {
            Issue.record("the items changed kind")
            return
        }
        #expect(track.id == "catalog/song/5" && track.duration == 212 && track.artwork?.id == "applemusic-art:applemusic://catalog/song/5")
        #expect(place.kind == "album" && place.id == "library-album/9" && place.subtitle == "Daft Punk")
    }

    @Test func accountsMapOneToOne() {
        #expect(AppleMusicProvider.account(.disconnected) == PakAccountState(.disconnected))
        #expect(AppleMusicProvider.account(.connected(name: nil)) == .connected)
        #expect(AppleMusicProvider.account(.limited(reason: "No subscription")) == PakAccountState(.limited, message: "No subscription"))
    }
}
