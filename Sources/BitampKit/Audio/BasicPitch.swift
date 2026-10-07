import AVFoundation
import CoreML

/// Spotify's Basic Pitch (github.com/spotify/basic-pitch, Apache 2.0): a small neural
/// network that hears the notes in any music, several at once. It takes two-second windows
/// of mono audio at 22,050 Hz (its constant-Q transform is inside the model) and gives, for
/// every 256 samples and each of the 88 piano keys, how likely a note is sounding there and
/// how likely one starts there. `decodeNotes` turns that into notes, as Basic Pitch's own
/// `note_creation.py` does.
///
/// Not for the render thread: predictions take about 10 ms a window.
final class BasicPitch: @unchecked Sendable {
    static let sampleRate = 22_050.0
    /// Audio per frame of output.
    static let fftHop = 256
    /// Samples per window: two seconds less a hop.
    static let windowSamples = 43_844
    static let framesPerWindow = 172
    /// Frames dropped from each end of a window, where the model hears less context.
    static let edgeFrames = 15
    static let keptFrames = framesPerWindow - 2 * edgeFrames
    /// Windows start this far apart, so the frames they keep tile the audio.
    static let windowHop = windowSamples - 2 * edgeFrames * fftHop
    /// The model's notes are the piano's: A0 (MIDI 21) up.
    static let lowestNote = 21
    static let noteCount = 88

    /// Basic Pitch's own defaults for when a note starts and how long it lasts.
    static let onsetThreshold: Float = 0.5
    static let frameThreshold: Float = 0.3
    /// Frames below `frameThreshold` a note may span before it counts as ended.
    static let energyTolerance = 11

    /// The model, compiled on first use, or nil when it couldn't be loaded.
    static let shared: BasicPitch? = {
        do {
            return try BasicPitch()
        } catch {
            NSLog("Bitamp: Basic Pitch is unavailable: \(error)")
            return nil
        }
    }()

    private let model: MLModel
    private let input: MLMultiArray
    /// Core ML doesn't promise a model is safe to use from two threads at once.
    private let lock = NSLock()

    init() throws {
        guard let url = Self.modelURL() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "nmp.mlpackage not found"])
        }
        let compiled = try Self.compiledModel(for: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
    }

    /// The compiled model, from the caches folder if this exact package was compiled before.
    /// Command Line Tools have no coremlcompiler, so the package is compiled at run time.
    static func compiledModel(for package: URL) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bitamp")
        let cached = caches.appendingPathComponent("BasicPitch-\(try fingerprint(of: package)).mlmodelc")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let compiled = try MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: compiled, to: cached)
            return cached
        } catch {
            // Another launch may have cached it first; the fresh copy works either way.
            return FileManager.default.fileExists(atPath: cached.path) ? cached : compiled
        }
    }

    /// Identifies a model package by its files' names and sizes, so a new model gets a new cache.
    static func fingerprint(of package: URL) throws -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let files = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.fileSizeKey])
        var entries: [String] = []
        while let file = files?.nextObject() as? URL {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            entries.append("\(file.path.replacingOccurrences(of: package.path, with: "")):\(size)")
        }
        for byte in entries.sorted().joined(separator: "|").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Where the model is: in Bitamp.app, `scripts/bundle.sh` copies the package's resource
    /// bundle into Contents/Resources; in a debug build or the tests it's beside the binary.
    static func modelURL() -> URL? {
        let resourceBundle = "Bitamp_BitampKit.bundle"
        let path = "BasicPitch/nmp.mlpackage"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                      Bundle(for: BasicPitch.self).bundleURL.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            for candidate in [place.appendingPathComponent(resourceBundle).appendingPathComponent(path),
                              place.appendingPathComponent(resourceBundle).appendingPathComponent("Contents/Resources").appendingPathComponent(path)]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Runs one window of `windowSamples` samples and writes the `keptFrames` middle frames'
    /// note and onset likelihoods, frame by frame, 88 to a frame.
    func predict(_ samples: UnsafePointer<Float>, notes: UnsafeMutablePointer<Float>, onsets: UnsafeMutablePointer<Float>) throws {
        lock.lock()
        defer { lock.unlock() }
        input.dataPointer.assumingMemoryBound(to: Float.self).update(from: samples, count: Self.windowSamples)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
        // Basic Pitch's names: Identity is the pitch contour, _1 the notes, _2 the onsets.
        for (name, destination) in [("Identity_1", notes), ("Identity_2", onsets)] {
            guard let array = output.featureValue(for: name)?.multiArrayValue, array.dataType == .float32 else {
                throw CocoaError(.coderValueNotFound)
            }
            let frameStride = array.strides[1].intValue, noteStride = array.strides[2].intValue
            let data = array.dataPointer.assumingMemoryBound(to: Float.self)
            for frame in 0..<Self.keptFrames {
                let row = data + (frame + Self.edgeFrames) * frameStride
                for note in 0..<Self.noteCount {
                    destination[frame * Self.noteCount + note] = row[note * noteStride]
                }
            }
        }
    }

    /// When frame `index` of the frames kept from window `window` starts, in seconds. Window
    /// `w` starts `edgeFrames` hops before sample `w * windowHop`, so its first kept frame
    /// starts there.
    static func time(window: Int, frame: Int) -> Double {
        Double(window * windowHop + frame * fftHop) / sampleRate
    }

    // MARK: - Notes

    /// A note as frames of the model's output.
    struct FrameNote: Equatable {
        var start: Int
        /// The first frame after the note.
        var end: Int
        var pitch: Int
        /// The mean note likelihood over the note, 0...1.
        var amplitude: Float
    }

    /// Basic Pitch's `output_to_notes_polyphonic`: notes start where an onset peaks over
    /// `onsetThreshold` (or the note likelihood jumps) and last while the likelihood stays
    /// over `frameThreshold`; then "the melodia trick" picks up notes that never had a clear
    /// onset, strongest first. `frames` and `onsets` are `count` frames of 88. Notes in
    /// `known` (already found by an earlier pass) are left out, and so are notes of
    /// `minimumLength` frames or fewer.
    static func decodeNotes(frames: [Float], onsets rawOnsets: [Float], count n: Int,
                            known: [FrameNote] = [], minimumLength: Int,
                            onsetThreshold: Float = onsetThreshold,
                            frameThreshold: Float = frameThreshold) -> [FrameNote] {
        let width = noteCount
        guard n > 2 else { return [] }

        // Onsets inferred from jumps in the note likelihood, scaled to the predicted ones.
        var onsets = rawOnsets
        var jumps = [Float](repeating: 0, count: n * width)
        var biggestJump: Float = 0
        for t in 2..<n {
            for f in 0..<width {
                let here = frames[t * width + f]
                let jump = max(0, min(here - frames[(t - 1) * width + f], here - frames[(t - 2) * width + f]))
                jumps[t * width + f] = jump
                biggestJump = max(biggestJump, jump)
            }
        }
        let biggestOnset = rawOnsets.max() ?? 0
        if biggestJump > 0 {
            let scale = biggestOnset / biggestJump
            for i in 0..<(n * width) { onsets[i] = max(onsets[i], jumps[i] * scale) }
        }

        var remaining = frames
        func clear(_ t: Int, _ f: Int) {
            remaining[t * width + f] = 0
            if f < width - 1 { remaining[t * width + f + 1] = 0 }
            if f > 0 { remaining[t * width + f - 1] = 0 }
        }
        for note in known {
            let f = note.pitch - lowestNote
            guard (0..<width).contains(f) else { continue }
            for t in max(0, note.start)..<min(n, max(note.end, 0)) { clear(t, f) }
        }

        var notes: [FrameNote] = []
        func mean(_ f: Int, _ start: Int, _ end: Int) -> Float {
            var total: Float = 0
            for t in start..<end { total += frames[t * width + f] }
            return total / Float(end - start)
        }

        // Onset peaks, latest first, as Basic Pitch walks them.
        for t in stride(from: n - 2, through: 1, by: -1) {
            for f in stride(from: width - 1, through: 0, by: -1) {
                let value = onsets[t * width + f]
                guard value >= onsetThreshold, value > onsets[(t - 1) * width + f],
                      value > onsets[(t + 1) * width + f] else { continue }
                var i = t + 1
                var k = 0
                while i < n - 1 && k < energyTolerance {
                    k = remaining[i * width + f] < frameThreshold ? k + 1 : 0
                    i += 1
                }
                i -= k
                guard i - t > minimumLength else { continue }
                for j in t..<i { clear(j, f) }
                notes.append(FrameNote(start: t, end: i, pitch: f + lowestNote, amplitude: mean(f, t, i)))
            }
        }

        // The melodia trick: grow a note out from each remaining peak, strongest first.
        var peaks: [(value: Float, index: Int)] = []
        for (index, value) in remaining.enumerated() where value > frameThreshold {
            peaks.append((value, index))
        }
        peaks.sort { $0.value != $1.value ? $0.value > $1.value : $0.index < $1.index }
        for peak in peaks where remaining[peak.index] > frameThreshold {
            let middle = peak.index / width, f = peak.index % width
            remaining[peak.index] = 0

            var i = middle + 1
            var k = 0
            while i < n - 1 && k < energyTolerance {
                k = remaining[i * width + f] < frameThreshold ? k + 1 : 0
                clear(i, f)
                i += 1
            }
            let end = i - 1 - k

            i = middle - 1
            k = 0
            while i > 0 && k < energyTolerance {
                k = remaining[i * width + f] < frameThreshold ? k + 1 : 0
                clear(i, f)
                i -= 1
            }
            let start = i + 1 + k

            guard end - start > minimumLength else { continue }
            notes.append(FrameNote(start: start, end: end, pitch: f + lowestNote, amplitude: mean(f, start, end)))
        }
        return notes
    }
}

/// Reads a file as Basic Pitch hears it: mono at 22,050 Hz, from any sample in its timeline.
final class BasicPitchReader {
    let file: AVAudioFile
    /// The file's length at 22,050 Hz.
    let length: Int
    private let sourceRate: Double
    private let mono: AVAudioFormat
    private let target: AVAudioFormat

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sourceRate = file.processingFormat.sampleRate
        length = Int(Double(file.length) * BasicPitch.sampleRate / sourceRate)
        mono = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
        target = AVAudioFormat(standardFormatWithSampleRate: BasicPitch.sampleRate, channels: 1)!
    }

    /// Fills `count` samples from sample `start` (which may be negative, or run past the end,
    /// where it reads silence).
    func read(from start: Int, count: Int, into out: UnsafeMutablePointer<Float>) throws {
        out.update(repeating: 0, count: count)
        let ratio = sourceRate / BasicPitch.sampleRate
        // A little extra either side so the resampler's filter has context.
        let margin = 64
        let sourceStart = max(0, Int((Double(start - margin) * ratio).rounded(.down)))
        let sourceEnd = min(Int(file.length), Int((Double(start + count + margin) * ratio).rounded(.up)))
        guard sourceEnd > sourceStart else { return }

        let frames = AVAudioFrameCount(sourceEnd - sourceStart)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames) else { return }
        file.framePosition = AVAudioFramePosition(sourceStart)
        try file.read(into: buffer, frameCount: frames)
        mixed.frameLength = buffer.frameLength
        let channels = Int(format.channelCount), length = Int(buffer.frameLength)
        let sum = mixed.floatChannelData![0]
        sum.update(repeating: 0, count: length)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for i in 0..<length { sum[i] += data[i] }
        }
        let gain = 1 / Float(channels)
        for i in 0..<length { sum[i] *= gain }

        guard let converter = AVAudioConverter(from: mono, to: target),
              let resampled = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(length) / ratio) + 64)
        else { return }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // Keeps the output aligned with the input, sample for sample.
        converter.primeMethod = .normal
        var given = false
        var error: NSError?
        converter.convert(to: resampled, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return mixed
        }
        if let error { throw error }

        // Resampled sample i is at sample `first + i` of the 22,050 Hz timeline.
        let first = Int((Double(sourceStart) / ratio).rounded())
        let data = resampled.floatChannelData![0]
        for i in 0..<Int(resampled.frameLength) {
            let position = first + i - start
            if position >= 0 && position < count { out[position] = data[i] }
        }
    }
}
