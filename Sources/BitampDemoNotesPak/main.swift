import BitampPakSDK
import Foundation

/// Bitamp's demo companion Pak: notes about the Demo Pak's public-domain tunes, written a
/// word at a time with a source for each, the way a Pak that asks a service on the web
/// would send them. It needs no network. Package it with
/// `scripts/make-pak.sh BitampDemoNotesPak`; see docs/PAK-SDK.md.
final class DemoNotesPak: PakProvider {
    private var short = false

    func configure(_ context: PakContext) async throws -> PakAccountState {
        short = context.settings["detail"] == "Short"
        return PakAccountState(.connected, message: "Notes on the Demo tunes")
    }

    func notes(for song: PakSongInfo, writer: PakNotesWriter) async throws {
        guard let notes = TuneNotes.all.first(where: { Self.fold($0.title) == Self.fold(song.title) }) else {
            writer.write("The Demo Notes Pak only knows the Demo Pak's tunes. Play one of those, such as Ode to Joy, "
                + "to see notes arrive a word at a time.")
            return
        }
        for (index, paragraph) in notes.paragraphs.enumerated() {
            if short, index > 0 { break }
            if index > 0 { writer.write("\n\n") }
            var first = true
            for word in paragraph.split(separator: " ") {
                // Cancelled when the song changes: Task.sleep throws, and the notes stop.
                try await Task.sleep(for: .milliseconds(25))
                writer.write((first ? "" : " ") + word)
                first = false
            }
            writer.cite([notes.source])
        }
    }

    /// "Für Elise" and "fur elise" match.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

struct TuneNotes {
    let title: String
    let paragraphs: [String]
    let source: PakCitation

    static let all = [
        TuneNotes(title: "Ode to Joy", paragraphs: [
            "Beethoven set Friedrich Schiller's poem of 1785 in the last movement of his Ninth Symphony, first played in Vienna in 1824.",
            "The melody was later taken up as the anthem of Europe, without Schiller's words.",
        ], source: PakCitation(title: "Ode to Joy", url: "https://en.wikipedia.org/wiki/Ode_to_Joy")),
        TuneNotes(title: "Für Elise", paragraphs: [
            "A short piano piece in A minor that Beethoven wrote around 1810. It was only published in 1867, forty years after he died.",
            "No one is sure who Elise was.",
        ], source: PakCitation(title: "Für Elise", url: "https://en.wikipedia.org/wiki/F%C3%BCr_Elise")),
        TuneNotes(title: "Greensleeves", paragraphs: [
            "An English folk song, registered as a ballad in London in 1580.",
            "It's often said that Henry VIII wrote it, but the style is from after his time.",
        ], source: PakCitation(title: "Greensleeves", url: "https://en.wikipedia.org/wiki/Greensleeves")),
        TuneNotes(title: "Twinkle, Twinkle, Little Star", paragraphs: [
            "The words are Jane Taylor's poem The Star, published in 1806.",
            "They're sung to the French tune Ah! vous dirai-je, maman, on which Mozart wrote twelve variations.",
        ], source: PakCitation(title: "Twinkle, Twinkle, Little Star", url: "https://en.wikipedia.org/wiki/Twinkle,_Twinkle,_Little_Star")),
        TuneNotes(title: "Frère Jacques", paragraphs: [
            "A French nursery song, usually sung as a round: each voice starts a line behind the one before.",
            "Mahler used it, in a minor key, in the slow movement of his First Symphony.",
        ], source: PakCitation(title: "Frère Jacques", url: "https://en.wikipedia.org/wiki/Fr%C3%A8re_Jacques")),
        TuneNotes(title: "Amazing Grace", paragraphs: [
            "John Newton's hymn, published in 1779 in the Olney Hymns.",
            "Since the 1830s it has usually been sung to the American tune New Britain.",
        ], source: PakCitation(title: "Amazing Grace", url: "https://en.wikipedia.org/wiki/Amazing_Grace")),
    ]
}

PakRunner.run(DemoNotesPak())
