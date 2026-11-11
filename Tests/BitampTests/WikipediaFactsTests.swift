import BitampPakKit
@testable import BitampBackstory
@testable import BitampKit
import Foundation
import Testing

/// Wikipedia lookups for the on-device model, with invented pages and no network.
@Suite struct WikipediaFactsTests {
    let song = PakNowPlaying(title: "Dial-Up Sunrise", artist: "The Low Bits", album: "Low Tide FM")

    static func page(_ title: String, _ description: String, _ lead: String, disambiguation: Bool = false) -> [String: Any] {
        var page: [String: Any] = ["title": title, "description": description, "extract": lead,
                                   "canonicalurl": "https://en.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_")]
        if disambiguation { page["pageprops"] = ["disambiguation": ""] }
        return page
    }

    static func results(_ pages: [[String: Any]]) -> Data {
        let indexed = pages.enumerated().map { index, page in page.merging(["index": index + 1]) { $1 } }
        return try! JSONSerialization.data(withJSONObject: ["query": ["pages": indexed]])
    }

    static func pages(_ pages: [[String: Any]]) -> [WikipediaFacts.Page] {
        WikipediaFacts.pages(from: results(pages))!
    }

    let songPage = page("Dial-Up Sunrise", "2003 single by the Low Bits",
                        "\"Dial-Up Sunrise\" is a song by the band the Low Bits, from their album Low Tide FM.")
    let albumPage = page("Low Tide FM", "2003 studio album by the Low Bits",
                         "Low Tide FM is the second studio album by the Low Bits.")
    let artistPage = page("The Low Bits", "American chiptune band, songwriters",
                          "The Low Bits are an American band formed in 1998.")

    @Test func picksTheSongByItsArtist() {
        let other = Self.page("Dial-Up Sunrise (Mira Vance song)", "2010 song by Mira Vance",
                              "\"Dial-Up Sunrise\" is a song by Mira Vance.")
        let pick = WikipediaFacts.pick(Self.pages([other, albumPage, songPage]), for: song)
        #expect(pick?.kind == .song)
        #expect(pick?.title == "Dial-Up Sunrise")
    }

    @Test func aSameNamedSongByAnotherArtistIsNotUsed() {
        let other = Self.page("Dial-Up Sunrise (Mira Vance song)", "2010 song by Mira Vance",
                              "\"Dial-Up Sunrise\" is a song by Mira Vance.")
        #expect(WikipediaFacts.pick(Self.pages([other]), for: song) == nil)
    }

    @Test func aDisambiguationPageIsNotUsed() {
        let list = Self.page("Dial-Up Sunrise", "single by the Low Bits, and other uses",
                             "\"Dial-Up Sunrise\" is a song by the Low Bits. It may also refer to:", disambiguation: true)
        #expect(WikipediaFacts.pick(Self.pages([list]), for: song) == nil)
    }

    @Test func fallsBackToTheAlbumThenTheArtist() {
        #expect(WikipediaFacts.pick(Self.pages([artistPage, albumPage]), for: song)?.kind == .album)
        // "songwriters" doesn't make the band's page a song's.
        #expect(WikipediaFacts.pick(Self.pages([artistPage]), for: song)?.kind == .artist)
    }

    @Test func aNameMentionedLaterDoesntCount() {
        let later = Self.page("Static Bloom", "2006 studio album by the Low Bits",
                              "Static Bloom is the third album by the Low Bits. It came three years after Low Tide FM.")
        #expect(WikipediaFacts.pick(Self.pages([later]), for: song) == nil)
    }

    @Test func findsATitleInAnotherScript() {
        let japanese = PakNowPlaying(title: "夜明けのモデム", artist: "ロービッツ")
        let romanized = Self.page("Yoake no Modemu", "2004 single by Rōbittsu",
                                  "\"Yoake no Modemu\" (Japanese: 夜明けのモデム) is a song by ロービッツ.")
        #expect(WikipediaFacts.pick(Self.pages([romanized]), for: japanese)?.kind == .song)
        #expect(WikipediaFacts.languages(for: japanese) == ["en", "ja"])
        #expect(WikipediaFacts.languages(for: song) == ["en"])
        #expect(WikipediaFacts.fold("プラスティック・ラヴ") == WikipediaFacts.fold("プラスティック・ラブ"))
        #expect(WikipediaFacts.fold("Beyoncé") == "beyonce")
    }

    @Test func keepsTheStoryAndCutsAtASentence() {
        let sections = """
        Lead text.

        == Background ==
        The band wrote it in a beach house. They used a modem.

        === Recording ===
        It took eight days.

        == Track listing ==
        1. Dial-Up Sunrise
        """
        let text = WikipediaFacts.trim(lead: "It is a song.", sections: sections, to: 1000)
        #expect(text.contains("beach house"))
        #expect(text.contains("eight days"))
        #expect(!text.contains("Track listing"))
        #expect(WikipediaFacts.trim(lead: "One. Two three four.", sections: "", to: 10) == "One.")
    }

    @Test func looksUpWithoutTheNetwork() async {
        let asked = Box<[URLRequest]>([])
        let songPage = self.songPage
        let facts = WikipediaFacts(fetch: { request in
            asked.value.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "titles" }) {
                return try JSONSerialization.data(withJSONObject: ["query": ["pages": [[
                    "extract": "Lead.\n== Background ==\nWritten in a beach house.\n== Personnel ==\nNobody."]]]])
            }
            return WikipediaFactsTests.results([songPage])
        }, version: "1.0")
        let article = await facts.article(for: song, characters: 2000)
        #expect(article?.kind == .song)
        #expect(article?.text.contains("beach house") == true)
        #expect(article?.text.contains("Personnel") == false)
        #expect(asked.value.first?.value(forHTTPHeaderField: "User-Agent") == "Bitamp/1.0 (https://github.com/ryanromanov/Bitamp)")
        let sent = asked.value.first.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(sent?.first { $0.name == "gsrsearch" }?.value == "Dial-Up Sunrise The Low Bits")
    }

    @Test func nothingWhenWikipediaCantBeReached() async {
        let facts = WikipediaFacts(fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await facts.article(for: song, characters: 2000) == nil)
    }

    @Test func thePromptSaysWhenTheArticleIsntAboutTheSong() {
        let album = WikipediaArticle(kind: .album, title: "Low Tide FM", url: URL(string: "https://en.wikipedia.org/wiki/Low_Tide_FM")!,
                                     text: "Low Tide FM is an album.")
        let prompt = WikipediaPrompt.prompt(for: song, article: album)
        #expect(prompt.contains("about the album \"Low Tide FM\" (there's no article about the song itself)"))
        #expect(prompt.hasSuffix("Low Tide FM is an album."))
    }
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
