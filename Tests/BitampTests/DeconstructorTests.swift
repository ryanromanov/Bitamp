import BitampPakKit
@testable import BitampBackstory
import Foundation
import Testing

/// MusicBrainz's answers, as it sent them for Johnny Cash's "Hurt" (trimmed), plus a song
/// with sampling links. Nothing here goes to the network.
@Suite struct DeconstructorTests {
    static let hurt = """
    {"id":"25d8de5e-3662-4ffd-8dea-511a696ac3e7","title":"Hurt","artist-credit":[{"name":"Johnny Cash","artist":{"name":"Johnny Cash"}}],
     "relations":[
      {"type":"producer","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"Rick Rubin"}},
      {"type":"producer","direction":"backward","target-type":"artist","attributes":["associate"],"artist":{"name":"John Carter Cash"}},
      {"type":"mix","direction":"backward","target-type":"artist","attributes":[],"artist":{"name":"David Ferguson"}},
      {"type":"instrument","direction":"backward","target-type":"artist","attributes":["piano"],"artist":{"name":"Benmont Tench"}},
      {"type":"mashes up","direction":"backward","target-type":"recording","attributes":[],"recording":{"id":"d6efa2cf-1c67-4c6a-b419-b6f429bb3b2b","title":"Hurt Like Poo"}},
      {"type":"performance","direction":"forward","target-type":"work","attributes":["cover"],
       "work":{"id":"ca56bd56-0e88-35f3-aec2-12eb8e9c739e","title":"Hurt","relations":[
         {"type":"composer","direction":"backward","target-type":"artist","artist":{"name":"Trent Reznor"}},
         {"type":"lyricist","direction":"backward","target-type":"artist","artist":{"name":"Trent Reznor"}},
         {"type":"other version","direction":"forward","target-type":"work","work":{"id":"w2","title":"Verletzt"}}]}}]}
    """

    static let sampler = """
    {"id":"24511aa9-5ba5-44f3-b7bf-aad6c7362803","title":"Intro","artist-credit":[{"name":"Maboo"}],
     "relations":[
      {"type":"samples material","direction":"forward","target-type":"recording","recording":{"id":"r-wire","title":"Through the Wire"}},
      {"type":"samples material","direction":"backward","target-type":"recording","recording":{"id":"r-later","title":"Later Song"}},
      {"type":"remix","direction":"forward","target-type":"recording","recording":{"id":"r-orig","title":"Original Mix"}}]}
    """

    private func recording(_ json: String) throws -> MBRecording {
        try JSONDecoder().decode(MBRecording.self, from: Data(json.utf8))
    }

    @Test func aCoverNamesItsOriginalAndWriters() throws {
        let found = Deconstructor.merge([try recording(Self.hurt)])
        #expect(found.coverOf == "Hurt")
        #expect(found.writers == ["Trent Reznor"])
        #expect(found.producers == ["Rick Rubin", "John Carter Cash"])
        #expect(found.mixers == ["David Ferguson"])
        #expect(found.workID == "ca56bd56-0e88-35f3-aec2-12eb8e9c739e")
        #expect(found.derived.map(\.kind) == ["mashed up in"])
    }

    @Test func samplingDirectionsAreNotMixedUp() throws {
        let found = Deconstructor.merge([try recording(Self.sampler)])
        #expect(found.samples.map(\.title) == ["Through the Wire"])
        #expect(found.sampledBy.map(\.title) == ["Later Song"])
        #expect(found.derived.map(\.kind) == ["remix of"])
        #expect(found.coverOf == nil)
    }

    @Test func severalRecordingsMergeWithoutRepeats() throws {
        // Only one of a song's recordings may carry the links; the same link twice shows once.
        let bare = try recording("{\"id\":\"x\",\"title\":\"Intro\"}")
        let found = Deconstructor.merge([bare, try recording(Self.sampler), try recording(Self.sampler)])
        #expect(found.samples.count == 1)
        #expect(found.sampledBy.count == 1)
    }

    @Test func onlyStrongMatchesWithTheSameTitleAreRead() throws {
        let hits = [
            try recording("{\"id\":\"a\",\"title\":\"Hurt\",\"score\":100}"),
            try recording("{\"id\":\"b\",\"title\":\"HURT!\",\"score\":95}"),
            try recording("{\"id\":\"c\",\"title\":\"Hurt Me\",\"score\":100}"),
            try recording("{\"id\":\"d\",\"title\":\"Hurt\",\"score\":60}"),
            try recording("{\"id\":\"a\",\"title\":\"Hurt\",\"score\":100}"),
        ]
        #expect(Deconstructor.pick(hits, title: "Hurt").map(\.id) == ["a", "b"])
    }

    @Test func theNotesNameTheArtistsAndKeepToPlainText() throws {
        var found = Deconstructor.merge([try recording(Self.sampler)])
        found.otherVersions = ["Zo\u{00E9}"]
        let matched = try recording(Self.sampler)
        let updates = Deconstructor.render(found, matched: matched, artists: ["r-wire": "Kanye West"])
        guard case .text(let head) = updates[0], case .cite(let sources) = updates[1], case .text(let body) = updates[2] else {
            Issue.record("a line naming the match, its source, then the findings: \(updates)"); return
        }
        #expect(head == "Matched \"Intro\" by Maboo.")
        #expect(sources.first?.url.absoluteString == "https://musicbrainz.org/recording/24511aa9-5ba5-44f3-b7bf-aad6c7362803")
        #expect(body.contains("SAMPLES\n- \"Through the Wire\" by Kanye West"))
        #expect(body.contains("SAMPLED BY\n- \"Later Song\""))
        #expect(body.contains("remix of: \"Original Mix\""))
        #expect(body.contains("- Zoe"))
        #expect(body.allSatisfy { $0.isASCII })
    }

    @Test func aSongWithNoLinksSaysSo() throws {
        let matched = try recording("{\"id\":\"x\",\"title\":\"Plain\"}")
        let updates = Deconstructor.render(Deconstructor.merge([matched]), matched: matched, artists: [:])
        guard case .text(let body) = updates.last else { Issue.record("unexpected notes"); return }
        #expect(body.contains("no sampling, cover, remix or credit links"))
    }

    @Test func listsAreCappedWithAPointerToTheRest() throws {
        var found = Deconstructor.Findings()
        found.samples = (0..<9).map { Deconstructor.Ref(id: "r\($0)", title: "Song \($0)") }
        let matched = try recording("{\"id\":\"x\",\"title\":\"Plain\"}")
        guard case .text(let body) = Deconstructor.render(found, matched: matched, artists: [:]).last else { Issue.record("unexpected notes"); return }
        #expect(body.contains("Song 5"))
        #expect(!(body.contains("Song 6")))
        #expect(body.contains("...and 3 more on MusicBrainz"))
        #expect(found.relatedIDs.count == 6)
    }

    // MARK: - The lookup, against a stand-in MusicBrainz

    private final class Requests: @unchecked Sendable {
        var urls: [URL] = []
        var agents: [String] = []
    }

    private func service(status: Int = 200, _ requests: Requests = Requests()) -> Deconstructor {
        Deconstructor(fetch: { request in
            requests.urls.append(request.url!)
            requests.agents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
            let path = request.url!.path
            let body: String
            if path.hasSuffix("/recording/25d8de5e-3662-4ffd-8dea-511a696ac3e7") {
                body = Self.hurt
            } else if request.url!.query?.contains("work=") == true {
                body = "{\"recordings\":[{\"id\":\"o1\",\"title\":\"Hurt\",\"artist-credit\":[{\"name\":\"Nine Inch Nails\"}]},{\"id\":\"o2\",\"title\":\"Hurt\",\"artist-credit\":[{\"name\":\"Johnny Cash\"}]}]}"
            } else if request.url!.query?.contains("rid") == true {
                body = "{\"recordings\":[{\"id\":\"d6efa2cf-1c67-4c6a-b419-b6f429bb3b2b\",\"title\":\"Hurt Like Poo\",\"artist-credit\":[{\"name\":\"Mashup Guy\"}]}]}"
            } else {
                body = "{\"recordings\":[{\"id\":\"25d8de5e-3662-4ffd-8dea-511a696ac3e7\",\"title\":\"Hurt\",\"score\":100,\"artist-credit\":[{\"name\":\"Johnny Cash\"}]}]}"
            }
            return (Data(body.utf8), status)
        }, version: "9.9")
    }

    private func collect(_ service: Deconstructor, _ song: PakNowPlaying) async throws -> [BackstoryUpdate] {
        var updates: [BackstoryUpdate] = []
        for try await update in service.notes(for: song) { updates.append(update) }
        return updates
    }

    @Test func aLookupAsksMusicBrainzAndWritesTheFindings() async throws {
        let requests = Requests()
        let updates = try await collect(service(requests), PakNowPlaying(title: "Hurt", artist: "Johnny Cash", album: "American IV"))
        guard case .text(let body) = updates.last else { Issue.record("\(updates)"); return }
        #expect(body.contains("This is a cover of \"Hurt\", written by Trent Reznor."))
        #expect(body.contains("mashed up in: \"Hurt Like Poo\" by Mashup Guy"))
        #expect(body.contains("- Nine Inch Nails"))
        #expect(!(body.contains("- Johnny Cash")))
        #expect(body.contains("Produced by Rick Rubin, John Carter Cash"))
        #expect(requests.agents.allSatisfy { $0 == "Bitamp/9.9 (https://github.com/ryanromanov/Bitamp)" })
        #expect(!(requests.urls.contains { $0.absoluteString.contains("@") }))
    }

    @Test func anUnknownSongIsSaidPlainly() async throws {
        let empty = Deconstructor(fetch: { _ in (Data("{\"recordings\":[]}".utf8), 200) })
        let updates = try await collect(empty, PakNowPlaying(title: "Nope", artist: "Nobody"))
        guard case .text(let body) = updates.first else { Issue.record("unexpected notes"); return }
        #expect(body.contains("no recording of this song"))
    }

    @Test func beingTurnedAwayIsAnErrorNotAnEmptyAnswer() async throws {
        for (status, expected) in [(503, "limited"), (429, "limited"), (500, "unavailable")] {
            do {
                _ = try await collect(service(status: status), PakNowPlaying(title: "Hurt", artist: "Johnny Cash"))
                Issue.record("status \(status) should throw")
            } catch let error as BackstoryError {
                switch (error, expected) {
                case (.limited, "limited"), (.unavailable, "unavailable"): break
                default: Issue.record("status \(status) gave \(error)")
                }
            }
        }
    }

    @Test func aSongWithoutAnArtistIsDeclined() async throws {
        do {
            _ = try await collect(service(), PakNowPlaying(title: "Hurt"))
            Issue.record("needs an artist")
        } catch let error as BackstoryError {
            #expect(error == .declined)
        }
    }

    @Test func theThrottleSpacesRequests() async {
        let throttle = MusicBrainzThrottle()
        let start = Date()
        await throttle.wait()
        await throttle.wait()
        #expect(Date().timeIntervalSince(start) >= 1.0)
    }

    @Test func aBusyMusicBrainzIsTriedAgainBeforeGivingUp() async throws {
        final class Count: @unchecked Sendable { var calls = 0 }
        let count = Count()
        let flaky = Deconstructor(fetch: { _ in
            count.calls += 1
            return count.calls <= 2 ? (Data(), 503) : (Data("{\"recordings\":[]}".utf8), 200)
        })
        let updates = try await collect(flaky, PakNowPlaying(title: "Nope", artist: "Nobody"))
        #expect(count.calls == 3)
        #expect(!updates.isEmpty)
    }
}
