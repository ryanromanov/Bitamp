import Foundation

/// Renders a tune as a chiptune-style 16-bit mono WAV file.
enum Synth {
    enum Waveform: String, CaseIterable {
        case square = "Square", triangle = "Triangle", sawtooth = "Sawtooth"
    }

    static let sampleRate = 44_100

    static func render(_ tune: Tune, waveform: Waveform, to url: URL) throws {
        var samples: [Int16] = []
        let secondsPerBeat = 60 / tune.beatsPerMinute
        for event in tune.events {
            let count = Int(event.beats * secondsPerBeat * Double(sampleRate))
            guard let midi = event.midi else {
                samples += [Int16](repeating: 0, count: count)
                continue
            }
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            // A short gap at the end of each note keeps repeated notes apart.
            let sounding = max(0, count - Int(0.03 * Double(sampleRate)))
            for i in 0..<count {
                guard i < sounding else {
                    samples.append(0)
                    continue
                }
                let phase = (Double(i) * frequency / Double(sampleRate)).truncatingRemainder(dividingBy: 1)
                let wave: Double
                switch waveform {
                case .square: wave = phase < 0.5 ? 1 : -1
                case .triangle: wave = 4 * abs(phase - 0.5) - 1
                case .sawtooth: wave = 2 * phase - 1
                }
                // 5 ms fades in and out, so notes don't click.
                let fade = min(1, Double(min(i, sounding - i)) / (0.005 * Double(sampleRate)))
                samples.append(Int16(wave * fade * 0.25 * Double(Int16.max)))
            }
        }
        try wav(samples).write(to: url, options: .atomic)
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
