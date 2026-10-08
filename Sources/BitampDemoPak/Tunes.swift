import Foundation

/// Public-domain melodies, as notes and beats: "E4" is a quarter note, "E4:2" a half,
/// "E4:0.5" an eighth, "R" a rest. Sharps are written "C#5".
struct Tune {
    let id: String
    let title: String
    let composer: String
    let beatsPerMinute: Double
    let notes: String

    var events: [(midi: Int?, beats: Double)] {
        notes.split(whereSeparator: \.isWhitespace).map { token in
            let parts = token.split(separator: ":")
            let beats = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
            return (Self.midi(String(parts[0])), beats)
        }
    }

    var duration: Double {
        events.reduce(0) { $0 + $1.beats } * 60 / beatsPerMinute
    }

    /// "A4" is 69. Nil for a rest or anything unreadable.
    static func midi(_ name: String) -> Int? {
        let steps: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let letter = name.first, let step = steps[letter], let octave = Int(String(name.last!)) else { return nil }
        let sharp = name.dropFirst().first == "#" ? 1 : 0
        return 12 * (octave + 1) + step + sharp
    }

    static let all: [Tune] = [
        Tune(id: "ode-to-joy", title: "Ode to Joy", composer: "Ludwig van Beethoven", beatsPerMinute: 132, notes: """
            E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4:1.5 D4:0.5 D4:2
            E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:1.5 C4:0.5 C4:2
            D4 D4 E4 C4 D4 E4:0.5 F4:0.5 E4 C4 D4 E4:0.5 F4:0.5 E4 D4 C4 D4 G3:2
            E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:1.5 C4:0.5 C4:2
            """),
        Tune(id: "fur-elise", title: "Für Elise", composer: "Ludwig van Beethoven", beatsPerMinute: 75, notes: """
            E5:0.5 D#5:0.5 E5:0.5 D#5:0.5 E5:0.5 B4:0.5 D5:0.5 C5:0.5 A4:1
            C4:0.5 E4:0.5 A4:0.5 B4:1 E4:0.5 G#4:0.5 B4:0.5 C5:1 E4:0.5
            E5:0.5 D#5:0.5 E5:0.5 D#5:0.5 E5:0.5 B4:0.5 D5:0.5 C5:0.5 A4:1
            C4:0.5 E4:0.5 A4:0.5 B4:1 E4:0.5 C5:0.5 B4:0.5 A4:2
            """),
        Tune(id: "greensleeves", title: "Greensleeves", composer: "Traditional", beatsPerMinute: 100, notes: """
            A4 C5:2 D5 E5:1.5 F5:0.5 E5 D5:2 B4 G4:1.5 A4:0.5 B4 C5:2 A4
            A4:1.5 G#4:0.5 A4 B4:2 G#4 E4:2 A4
            C5:2 D5 E5:1.5 F5:0.5 E5 D5:2 B4 G4:1.5 A4:0.5 B4
            C5:1.5 B4:0.5 A4 G#4:1.5 F#4:0.5 G#4 A4:3
            """),
        Tune(id: "twinkle-twinkle", title: "Twinkle, Twinkle, Little Star", composer: "Traditional", beatsPerMinute: 120, notes: """
            C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2
            G4 G4 F4 F4 E4 E4 D4:2 G4 G4 F4 F4 E4 E4 D4:2
            C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2
            """),
        Tune(id: "frere-jacques", title: "Frère Jacques", composer: "Traditional", beatsPerMinute: 120, notes: """
            C4 D4 E4 C4 C4 D4 E4 C4 E4 F4 G4:2 E4 F4 G4:2
            G4:0.5 A4:0.5 G4:0.5 F4:0.5 E4 C4 G4:0.5 A4:0.5 G4:0.5 F4:0.5 E4 C4
            C4 G3 C4:2 C4 G3 C4:2
            """),
        Tune(id: "amazing-grace", title: "Amazing Grace", composer: "Traditional", beatsPerMinute: 90, notes: """
            D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 G4:2 E4 D4:2
            D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 D5:3 R:2
            B4 D5:1.5 B4:0.5 D5:0.5 B4:0.5 G4:2 D4 E4:1.5 G4:0.5 G4:0.5 E4:0.5 D4:2
            D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 G4:3
            """),
    ]
}
