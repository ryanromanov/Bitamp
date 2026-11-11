import BitampPakKit
import Foundation

/// A Wikipedia article about the song, or, when the song has none, its album or artist.
public struct WikipediaArticle: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case song, album, artist }

    public var kind: Kind
    public var title: String
    public var url: URL
    /// Plain text: the lead, then sections such as Background and Recording, trimmed to fit.
    public var text: String
}

/// Finds a song's Wikipedia article for the on-device model to write from, since from memory
/// it knows little and can make things up. Sends only the title, artist and album, and only
/// when the user has turned this on.
///
/// One search request returns the candidates with their short descriptions ("1991 single by
/// Nirvana") and leads, which is enough to pick a page; a second fetches the chosen page's
/// sections. A page is used only when it clearly is this song (or its album or artist): a
/// same-named song by someone else would give notes that look sourced and are wrong.
public struct WikipediaFacts: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    let fetch: Fetch
    let userAgent: String

    public init(fetch: Fetch? = nil, version: String = Self.appVersion) {
        self.fetch = fetch ?? { request in try await URLSession.shared.data(for: request).0 }
        userAgent = "Bitamp/\(version) (https://github.com/ryanromanov/Bitamp)"
    }

    /// The app's version, or "dev" where there's no bundle (a debug build).
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The article, with at most `characters` of text, or nil when none is clearly about this
    /// song, its album or its artist, or Wikipedia can't be reached.
    public func article(for track: PakNowPlaying, characters: Int) async -> WikipediaArticle? {
        guard let artist = track.artist, !Self.fold(artist).isEmpty else { return nil }
        for language in Self.languages(for: track) {
            // The song search often brings up the album and artist too.
            var found = await search("\(track.title) \(artist)", language).flatMap { Self.pick($0, for: track) }
            if found == nil || found?.kind == .artist, let album = track.album {
                let albumPick = await search("\(album) \(artist)", language).flatMap { Self.pick($0, for: track) }
                if albumPick?.kind == .album { found = albumPick }
            }
            if found == nil {
                found = await search(artist, language).flatMap { Self.pick($0, for: track) }
            }
            if let found {
                let sections = found.kind == .song ? await self.sections(of: found.title, language) : nil
                return WikipediaArticle(kind: found.kind, title: found.title, url: found.url,
                                        text: Self.trim(lead: found.lead, sections: sections ?? "", to: characters))
            }
        }
        return nil
    }

    // MARK: - Requests

    struct Page: Equatable {
        var title: String
        var url: URL
        var description: String
        var lead: String
        var isDisambiguation: Bool
    }

    private func search(_ query: String, _ language: String) async -> [Page]? {
        let items = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"), URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query), URLQueryItem(name: "gsrlimit", value: "5"),
            URLQueryItem(name: "prop", value: "description|extracts|pageprops|info"), URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "ppprop", value: "disambiguation"), URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"), URLQueryItem(name: "exlimit", value: "5"),
        ]
        guard let data = await get(language, items) else { return nil }
        return Self.pages(from: data)
    }

    /// The page's text with `== Heading ==` lines, for picking sections.
    private func sections(of title: String, _ language: String) async -> String? {
        let items = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"), URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "prop", value: "extracts"), URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsectionformat", value: "wiki"),
        ]
        guard let data = await get(language, items),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return nil }
        return pages.first?["extract"] as? String
    }

    private func get(_ language: String, _ items: [URLQueryItem]) async -> Data? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 4)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try? await fetch(request)
    }

    static func pages(from data: Data) -> [Page]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return [] }
        return pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap { page in
            guard let title = page["title"] as? String,
                  let url = (page["canonicalurl"] as? String ?? page["fullurl"] as? String).flatMap(URL.init) else { return nil }
            return Page(title: title, url: url, description: page["description"] as? String ?? "",
                        lead: page["extract"] as? String ?? "",
                        isDisambiguation: (page["pageprops"] as? [String: Any])?["disambiguation"] != nil)
        }
    }

    // MARK: - Matching

    struct Pick: Equatable {
        var kind: WikipediaArticle.Kind
        var title: String
        var url: URL
        var lead: String
    }

    private static let songWords = ["song", "single", "楽曲", "曲", "シングル", "노래", "곡", "歌曲", "песня", "сингл"]
    private static let albumWords = ["album", "アルバム", "앨범", "专辑", "專輯", "альбом"]

    /// The song's page if there is one, else its album's, else its artist's.
    static func pick(_ pages: [Page], for track: PakNowPlaying) -> Pick? {
        guard let artist = track.artist else { return nil }
        let pages = pages.filter { !$0.isDisambiguation }
        func pick(_ kind: WikipediaArticle.Kind, _ page: Page) -> Pick {
            Pick(kind: kind, title: page.title, url: page.url, lead: page.lead)
        }
        if let page = pages.first(where: { names($0, track.title) && byArtist($0, artist) && says($0, songWords) }) {
            return pick(.song, page)
        }
        if let album = track.album,
           let page = pages.first(where: { names($0, album) && byArtist($0, artist) && says($0, albumWords) }) {
            return pick(.album, page)
        }
        if let page = pages.first(where: { fold(bare($0.title)) == fold(artist) && !says($0, songWords + albumWords) }) {
            return pick(.artist, page)
        }
        return nil
    }

    /// Whether the page is about `name`: its title says so, leaving out "(song)" or
    /// "(Nirvana song)", or its first sentence does, as with a title in another script
    /// ("Yoru ni Kakeru" (Japanese: 夜に駆ける)).
    static func names(_ page: Page, _ name: String) -> Bool {
        let name = fold(name)
        guard !name.isEmpty else { return false }
        return fold(bare(page.title)) == name || fold(firstSentence(page.lead)).contains(name)
    }

    /// Up to the first full stop, at most 150 characters: where an article names its subject,
    /// unlike a later "the follow-up to Variety".
    static func firstSentence(_ text: String) -> String {
        let start = text.prefix(150)
        guard let end = start.firstIndex(where: { ".。".contains($0) }) else { return String(start) }
        return String(start[..<end])
    }

    /// Whether the page's description, or its lead where it has none, names the artist.
    static func byArtist(_ page: Page, _ artist: String) -> Bool {
        let artist = fold(artist)
        guard artist.count >= 2 else { return false }
        return fold(page.description).contains(artist) || fold(String(page.lead.prefix(300))).contains(artist)
    }

    /// Whether the description, or the lead's start where there's no description, uses one of
    /// `words`: whole words in Latin and Cyrillic, so "songwriter" isn't a song.
    static func says(_ page: Page, _ words: [String]) -> Bool {
        let text = (page.description.isEmpty ? String(page.lead.prefix(200)) : page.description).lowercased()
        return words.contains { word in
            guard word.unicodeScalars.allSatisfy({ $0.value < 0x0500 }) else { return text.contains(word) }
            return text.range(of: "(^|[^\\p{L}])\(word)($|[^\\p{L}])", options: .regularExpression) != nil
        }
    }

    /// The title without a trailing "(…)".
    static func bare(_ title: String) -> String {
        guard title.hasSuffix(")"), let open = title.lastIndex(of: "(") else { return title }
        return title[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased, without accents, spaces or punctuation, so "Beyoncé" finds "Beyonce" and
    /// "竹内まりや" finds "竹内 まりや". Katakana ヴ counts as ブ, as in "プラスティック・ラヴ"
    /// for "プラスティック・ラブ".
    static func fold(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "ヴ", with: "ブ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// English Wikipedia first, then the one in the title's script, if it isn't Latin.
    static func languages(for track: PakNowPlaying) -> [String] {
        var languages = ["en"]
        let scalars = (track.title + (track.artist ?? "")).unicodeScalars
        func has(_ ranges: ClosedRange<UInt32>...) -> Bool {
            scalars.contains { scalar in ranges.contains { $0.contains(scalar.value) } }
        }
        if has(0x3040...0x30FF) { languages.append("ja") }           // kana
        else if has(0xAC00...0xD7AF, 0x1100...0x11FF) { languages.append("ko") }
        else if has(0x4E00...0x9FFF) { languages.append("zh") }     // Han without kana
        else if has(0x0400...0x04FF) { languages.append("ru") }
        else if has(0x0370...0x03FF) { languages.append("el") }
        return languages
    }

    // MARK: - Text

    private static let storyHeadings = [
        "background", "recording", "composition", "writing", "production", "release", "lyrics", "music video",
        "背景", "制作", "レコーディング", "歌詞", "リリース", "배경", "制作", "创作",
    ]

    /// The lead, then the sections that tell the song's story, cut at a sentence to fit.
    static func trim(lead: String, sections: String, to characters: Int) -> String {
        var text = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        var keep = false
        var story: [String] = []
        for line in sections.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=="), trimmed.hasSuffix("==") {
                let heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "= ")).lowercased()
                // A subsection keeps its parent's choice.
                if !trimmed.hasPrefix("===") { keep = storyHeadings.contains { heading.contains($0) } }
                if keep { story.append("\n" + heading.capitalized + ":") }
            } else if keep, !trimmed.isEmpty {
                story.append(trimmed)
            }
        }
        if !story.isEmpty { text += "\n" + story.joined(separator: "\n") }
        guard text.count > characters else { return text }
        let cut = String(text.prefix(characters))
        let end = cut.lastIndex { ".。!?！？".contains($0) }
        return end.map { String(cut[...$0]) } ?? cut
    }
}
