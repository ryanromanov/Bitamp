import BitampPakKit
import Foundation

/// What MusicBrainz knows about how a song was made: what it samples and what sampled it,
/// whether it's a cover, its remixes and mashups, other versions of the song, and who wrote,
/// produced and mixed it. The notes come from open data, with no key and no model, and each
/// is backed by a MusicBrainz page.
///
/// MusicBrainz keeps these links on individual recordings, and a song often has several
/// (the album cut, a single, a live take), of which only one may carry them. So the top
/// matches are read, in order, until one carries links, and what they say is merged.
public struct Deconstructor: BackstoryService {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    let fetch: Fetch
    let userAgent: String
    let pause: @Sendable () async -> Void

    /// A real lookup is paced to MusicBrainz's limit of a request a second, app-wide.
    public init() {
        self.init(fetch: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }, version: WikipediaFacts.appVersion, pause: { await MusicBrainzThrottle.shared.wait() })
    }

    init(fetch: @escaping Fetch, version: String = "dev", pause: @escaping @Sendable () async -> Void = {}) {
        self.fetch = fetch
        self.pause = pause
        userAgent = "Bitamp/\(version) (https://github.com/ryanromanov/Bitamp)"
    }

    static let base = "https://musicbrainz.org/ws/2/"
    /// How many recordings of the song are read, and how many links of each kind are shown.
    static let candidateLimit = 5
    static let listLimit = 6

    public func notes(for track: PakNowPlaying) -> AsyncThrowingStream<BackstoryUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for update in try await lookup(track) { continuation.yield(update) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func lookup(_ track: PakNowPlaying) async throws -> [BackstoryUpdate] {
        guard let artist = track.artist, !artist.isEmpty else { throw BackstoryError.declined }
        // The recording on this album comes first, but it's often a bare copy of a song whose
        // links sit on another recording, so the search without the album follows it.
        var hits: [MBRecording] = []
        if track.album != nil { hits = try await search(title: track.title, artist: artist, album: track.album) }
        hits += try await search(title: track.title, artist: artist, album: nil)
        let candidates = Self.pick(hits, title: track.title).prefix(Self.candidateLimit)
        guard let first = candidates.first else {
            return [.text("MusicBrainz has no recording of this song, so there is nothing to take apart.")]
        }
        // Read recordings until one carries links, which is usually the first or second.
        var details: [MBRecording] = []
        for candidate in candidates {
            details.append(try await recording(candidate.id))
            if Self.merge(details).hasLinks { break }
        }
        var found = Self.merge(details)
        let workID = found.workID
        var others: [MBRecording] = []
        if let workID {
            others = (try? await recordings(ofWork: workID)) ?? []
        }
        // The related recordings come without artists, so one search names them all.
        let related = found.relatedIDs
        let names = related.isEmpty ? [:] : ((try? await artists(of: related)) ?? [:])
        found.otherVersions = Self.otherVersions(others, besides: artist)
        return Self.render(found, matched: first, artists: names)
    }

    // MARK: - MusicBrainz

    private func search(title: String, artist: String, album: String?) async throws -> [MBRecording] {
        var query = "recording:\"\(Self.quote(title))\" AND artist:\"\(Self.quote(artist))\""
        if let album, !album.isEmpty { query += " AND release:\"\(Self.quote(album))\"" }
        let page: MBSearch = try await get("recording", ["query": query, "limit": "6"])
        return page.recordings
    }

    private func recording(_ id: String) async throws -> MBRecording {
        try await get("recording/\(id)", ["inc": "recording-rels+work-rels+work-level-rels+artist-rels+artist-credits"])
    }

    private func recordings(ofWork id: String) async throws -> [MBRecording] {
        let page: MBSearch = try await get("recording", ["work": id, "inc": "artist-credits", "limit": "60"])
        return page.recordings
    }

    private func artists(of ids: [String]) async throws -> [String: String] {
        let query = "rid:(" + ids.joined(separator: " OR ") + ")"
        let page: MBSearch = try await get("recording", ["query": query, "limit": String(ids.count)])
        return Dictionary(page.recordings.map { ($0.id, $0.artistName ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        var components = URLComponents(string: Self.base + path)!
        components.queryItems = (query.sorted { $0.key < $1.key } + [(key: "fmt", value: "json")]).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        try Task.checkCancellation()
        await pause()
        try Task.checkCancellation()
        let data: Data, status: Int
        do {
            (data, status) = try await fetch(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackstoryError.offline("MusicBrainz couldn't be reached.")
        }
        switch status {
        case 200: break
        case 429, 503: throw BackstoryError.limited("MusicBrainz is asking for a pause. Try again in a minute.")
        default: throw BackstoryError.unavailable("MusicBrainz answered with an error (\(status)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackstoryError.failed("MusicBrainz sent something unexpected.")
        }
    }

    /// A value inside a quoted Lucene phrase.
    static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ")
    }

    // MARK: - Reading

    /// Lowercase, without accents or punctuation, for comparing names.
    static func fold(_ text: String) -> String {
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(plain.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The hits that are this song: a strong score and the same title, best first.
    static func pick(_ hits: [MBRecording], title: String) -> [MBRecording] {
        let wanted = fold(title)
        var seen = Set<String>()
        return hits.filter { ($0.score ?? 0) >= 90 && fold($0.title) == wanted && seen.insert($0.id).inserted }
    }

    /// The relations of a song's several recordings, as one set of findings.
    static func merge(_ recordings: [MBRecording]) -> Findings {
        var found = Findings()
        func add(_ ref: Ref, to keyPath: WritableKeyPath<Findings, [Ref]>) {
            if !found[keyPath: keyPath].contains(where: { $0.id == ref.id }) { found[keyPath: keyPath].append(ref) }
        }
        for recording in recordings {
            for relation in recording.relations ?? [] {
                switch (relation.targetType, relation.type) {
                case ("recording", _):
                    guard let other = relation.recording else { continue }
                    let ref = Ref(id: other.id, title: other.title)
                    switch (relation.type, relation.direction) {
                    case ("samples material", "forward"): add(ref, to: \.samples)
                    case ("samples material", "backward"): add(ref, to: \.sampledBy)
                    case ("remix", "forward"): add(Ref(id: ref.id, title: ref.title, kind: "remix of"), to: \.derived)
                    case ("remix", "backward"): add(Ref(id: ref.id, title: ref.title, kind: "remixed as"), to: \.derived)
                    case ("mashes up", "forward"): add(Ref(id: ref.id, title: ref.title, kind: "mashes up"), to: \.derived)
                    case ("mashes up", "backward"): add(Ref(id: ref.id, title: ref.title, kind: "mashed up in"), to: \.derived)
                    case ("DJ-mix", "backward"): add(Ref(id: ref.id, title: ref.title, kind: "mixed into"), to: \.derived)
                    default: break
                    }
                case ("work", "performance"):
                    guard let work = relation.work else { continue }
                    if found.workID == nil { found.workID = work.id; found.workTitle = work.title }
                    if (relation.attributes ?? []).contains("cover") { found.coverOf = work.title }
                    for credit in work.relations ?? [] where credit.targetType == "artist" {
                        guard let name = credit.artist?.name, ["composer", "writer", "lyricist"].contains(credit.type) else { continue }
                        if !found.writers.contains(name) { found.writers.append(name) }
                    }
                case ("artist", "producer"):
                    if let name = relation.artist?.name, !found.producers.contains(name) { found.producers.append(name) }
                case ("artist", "mix"):
                    if let name = relation.artist?.name, !found.mixers.contains(name) { found.mixers.append(name) }
                default: break
                }
            }
        }
        return found
    }

    /// The other artists' recordings of the song, once each.
    static func otherVersions(_ recordings: [MBRecording], besides artist: String) -> [String] {
        var seen = Set([fold(artist)]), names: [String] = []
        for name in recordings.compactMap(\.artistName) where seen.insert(fold(name)).inserted { names.append(name) }
        return names
    }

    // MARK: - Writing

    /// The notes: plain ASCII, as the window's pixel font draws it.
    static func render(_ found: Findings, matched: MBRecording, artists: [String: String]) -> [BackstoryUpdate] {
        func label(_ ref: Ref) -> String {
            let by = artists[ref.id].flatMap { $0.isEmpty ? nil : " by \($0)" } ?? ""
            return "\"\(ref.title)\"\(by)"
        }
        func list(_ heading: String, _ lines: [String], total: Int) -> String {
            guard !lines.isEmpty else { return "" }
            let more = total > lines.count ? "\n...and \(total - lines.count) more on MusicBrainz" : ""
            return "\n\n\(heading)\n" + lines.map { "- \($0)" }.joined(separator: "\n") + more
        }
        let limit = listLimit
        var text = "Matched \"\(matched.title)\"\(matched.artistName.map { " by \($0)" } ?? "")."
        let source = BackstorySource(title: "MusicBrainz: \(matched.title)", url: URL(string: "https://musicbrainz.org/recording/\(matched.id)")!)
        var updates: [BackstoryUpdate] = []
        func flush() { updates.append(.text(text)); text = "" }
        flush()
        updates.append(.cite([source]))

        if let original = found.coverOf {
            let writers = found.writers.isEmpty ? "" : ", written by " + found.writers.joined(separator: ", ")
            text += "\n\nCOVER\nThis is a cover of \"\(original)\"\(writers)."
        } else if !found.writers.isEmpty {
            text += "\n\nWRITTEN BY\n" + found.writers.joined(separator: ", ")
        }
        text += list("SAMPLES", found.samples.prefix(limit).map(label), total: found.samples.count)
        text += list("SAMPLED BY", found.sampledBy.prefix(limit).map(label), total: found.sampledBy.count)
        text += list("REMIXES AND MASHUPS", found.derived.prefix(limit).map { "\($0.kind ?? "related"): \(label($0))" }, total: found.derived.count)
        text += list("OTHER VERSIONS OF THE SONG", found.otherVersions.prefix(limit).map { $0 }, total: found.otherVersions.count)
        var makers: [String] = []
        if !found.producers.isEmpty { makers.append("Produced by " + found.producers.joined(separator: ", ")) }
        if !found.mixers.isEmpty { makers.append("Mixed by " + found.mixers.joined(separator: ", ")) }
        text += list("MADE BY", makers, total: makers.count)
        if found.isEmpty {
            text += "\n\nMusicBrainz has no sampling, cover, remix or credit links for this song yet. Its data is added by volunteers, so many songs have none."
        }
        flush()
        return updates.map { update in
            if case .text(let words) = update { return .text(NotesText.ascii(words)) }
            return update
        }
    }

    // MARK: - Shapes

    struct Ref: Equatable {
        var id: String
        var title: String
        /// How a remix or mashup relates to the song: "remix of", "mashed up in".
        var kind: String?
    }

    struct Findings: Equatable {
        var workID: String?
        var workTitle: String?
        var coverOf: String?
        var writers: [String] = []
        var producers: [String] = []
        var mixers: [String] = []
        var samples: [Ref] = []
        var sampledBy: [Ref] = []
        var derived: [Ref] = []
        var otherVersions: [String] = []

        /// The recordings named in links, whose artists need looking up, as many as are shown.
        var relatedIDs: [String] {
            let limit = Deconstructor.listLimit
            return (samples.prefix(limit) + sampledBy.prefix(limit) + derived.prefix(limit)).map(\.id)
        }

        /// Whether anything ties the song to another, as a sample, a cover or a remix.
        var hasLinks: Bool { coverOf != nil || !samples.isEmpty || !sampledBy.isEmpty || !derived.isEmpty }

        var isEmpty: Bool {
            coverOf == nil && writers.isEmpty && producers.isEmpty && mixers.isEmpty
                && samples.isEmpty && sampledBy.isEmpty && derived.isEmpty && otherVersions.isEmpty
        }
    }
}

/// Plain letters for the pixel font: accents and typographic marks made plain.
enum NotesText {
    static func ascii(_ text: String) -> String {
        var out = text
        for (fancy, plain) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                               ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2026}", "..."), ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: fancy, with: plain)
        }
        let folded = out.folding(options: .diacriticInsensitive, locale: nil)
        return String(folded.unicodeScalars.map { $0.isASCII ? Character($0) : "?" })
    }
}

/// Spaces requests at least 1.1 seconds apart, for the whole app, since MusicBrainz allows a
/// request a second and blocks clients that go faster.
actor MusicBrainzThrottle {
    static let shared = MusicBrainzThrottle()
    private var next = Date.distantPast

    func wait() async {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(1.1)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

// MARK: - MusicBrainz's JSON, as much as is read

struct MBSearch: Decodable {
    var recordings: [MBRecording] = []
}

struct MBRecording: Decodable, Equatable {
    var id: String
    var title: String
    var score: Int?
    var artistCredit: [MBCredit]?
    var relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id, title, score, relations
        case artistCredit = "artist-credit"
    }

    var artistName: String? {
        guard let credit = artistCredit, !credit.isEmpty else { return nil }
        return credit.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
    }
}

struct MBCredit: Decodable, Equatable {
    var name: String?
    var joinphrase: String?
    var artist: MBArtist?
}

struct MBArtist: Decodable, Equatable {
    var name: String
}

struct MBWork: Decodable, Equatable {
    var id: String
    var title: String
    var relations: [MBRelation]?
}

struct MBRelation: Decodable, Equatable {
    var type: String
    var direction: String
    var targetType: String
    var attributes: [String]?
    var recording: MBRecording?
    var work: MBWork?
    var artist: MBArtist?

    enum CodingKeys: String, CodingKey {
        case type, direction, attributes, recording, work, artist
        case targetType = "target-type"
    }
}
