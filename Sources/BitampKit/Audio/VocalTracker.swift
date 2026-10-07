import Foundation

/// Follows the sung melody through a song with MSNet, a stretch at a time, as a pitch for
/// each `ChipScore` tick. A tick (256 samples at 22,050 Hz) is exactly two MSNet frames
/// (256 samples at 44.1 kHz).
///
/// `cfp.py` scales the features by their peaks over all the audio it's given, and MSNet's
/// idea of what's sung shifts with that scale. The clips it was tuned on by ear were 20 to
/// 30 seconds long, so each stretch here is scaled by the peaks within 10 seconds either
/// side of it. The features are worked out in chunks, on several cores, and kept until used.
///
/// Not thread-safe: use it from one thread at a time.
final class VocalTracker {
    /// Frames computed past each end of a stretch and then dropped: the network looks 14
    /// frames either way.
    static let marginFrames = 96
    /// How far either side of a stretch its features' peaks are taken from: 10 seconds.
    static let normalisingFrames = Int(10 * CFP.sampleRate) / CFP.hop
    static let chunkFrames = 512

    typealias Read = (_ start: Int, _ count: Int, _ into: UnsafeMutablePointer<Float>) throws -> Void

    private let model: MSNet
    /// Fills samples of the song, mono at 44.1 kHz.
    private let read: Read
    /// The song's length in samples, and in frames.
    let length: Int
    let frameCount: Int
    private let workers: Int
    private var cfps: [CFP] = []
    /// The maps of chunks worked out and not yet left behind, by chunk.
    private var chunkMaps: [Int: CFP.Maps] = [:]
    /// Each frame's largest log(1 + x) per map, for every chunk worked out, by chunk.
    private var chunkPeaks: [Int: [SIMD3<Float>]] = [:]

    init(model: MSNet, length: Int, read: @escaping Read) {
        self.model = model
        self.length = length
        self.read = read
        frameCount = CFP.frameCount(samples: length)
        workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// MSNet's pitch bin for each frame in `frames` (0 when no one sings). Frame c is centred
    /// on sample 256(c + 1) − 1; frames outside the song come out 0.
    func bins(frames: Range<Int>) throws -> [Int] {
        var bins: [Int] = []
        // Stretches the model can take in one go, margins included.
        let most = MSNet.frameRange.upperBound - 2 * Self.marginFrames
        for first in stride(from: frames.lowerBound, to: frames.upperBound, by: most) {
            let core = first..<min(frames.upperBound, first + most)
            let computed = (core.lowerBound - Self.marginFrames)..<(core.upperBound + Self.marginFrames)
            let normalising = (core.lowerBound - Self.normalisingFrames)..<(core.upperBound + Self.normalisingFrames)
            try work(peaks: normalising, maps: computed)
            // Chunks behind this stretch won't be needed again unless the playhead jumps back.
            for chunk in chunkMaps.keys where (chunk + 1) * Self.chunkFrames <= computed.lowerBound {
                chunkMaps[chunk] = nil
            }
            let all = try model.pitchBins(features: CFP.features(maps(for: computed), peaks: peaks(over: normalising)),
                                          frames: computed.count)
            bins += all[Self.marginFrames..<(Self.marginFrames + core.count)]
        }
        return bins
    }

    /// The voice's pitch in each tick of `ticks`, as a fractional MIDI note, or nil when
    /// fewer than half its frames are voiced. With both of a tick's frames voiced, it takes
    /// the higher, as the harness's median did.
    func pitches(ticks: Range<Int>) throws -> [Double?] {
        guard !ticks.isEmpty else { return [] }
        // Tick t covers frames 2t − 1 and 2t.
        let first = 2 * ticks.lowerBound - 1
        let bins = try self.bins(frames: first..<(2 * ticks.upperBound))
        return ticks.map { tick in
            let pair = [bins[2 * tick - 1 - first], bins[2 * tick - first]].filter { $0 > 0 }
            guard let bin = pair.max() else { return nil }
            return 69 + 12 * log2(MSNet.frequency(ofBin: bin) / 440)
        }
    }

    private func chunks(_ frames: Range<Int>) -> Range<Int> {
        let first = max(0, frames.lowerBound) / Self.chunkFrames
        let end = (min(frameCount, frames.upperBound) + Self.chunkFrames - 1) / Self.chunkFrames
        return first..<max(first, end)
    }

    /// Works out, on `workers` threads, the chunks whose peaks are wanted over `peakFrames`
    /// or whose maps are wanted over `mapFrames` and aren't to hand.
    private func work(peaks peakFrames: Range<Int>, maps mapFrames: Range<Int>) throws {
        let missing = Set(chunks(peakFrames).filter { chunkPeaks[$0] == nil } + chunks(mapFrames).filter { chunkMaps[$0] == nil })
            .sorted()
        guard !missing.isEmpty else { return }
        while cfps.count < workers { cfps.append(CFP()) }

        // The audio first, on this thread: each chunk's frames and 1,024 samples either side,
        // cut off where the song is, as `cfp.py` cuts its windows off there.
        let half = (CFP.windowLength - 1) / 2
        var audio: [[Float]] = []
        var centres: [[Int]] = []
        for chunk in missing {
            let frames = (chunk * Self.chunkFrames)..<min(frameCount, (chunk + 1) * Self.chunkFrames)
            let start = max(0, CFP.hop * (frames.lowerBound + 1) - 1 - half)
            let end = min(length, CFP.hop * frames.upperBound + half)
            var samples = [Float](repeating: 0, count: end - start)
            try samples.withUnsafeMutableBufferPointer { try read(start, $0.count, $0.baseAddress!) }
            audio.append(samples)
            centres.append(frames.map { CFP.hop * ($0 + 1) - 1 - start })
        }

        var results = [CFP.Maps?](repeating: nil, count: missing.count)
        let cfps = self.cfps, workers = min(self.workers, missing.count)
        results.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for index in stride(from: worker, to: missing.count, by: workers) {
                    results[index] = audio[index].withUnsafeBufferPointer { cfps[worker].maps($0, centres: centres[index]) }
                }
            }
        }
        for (chunk, maps) in zip(missing, results) {
            guard let maps else { continue }
            chunkMaps[chunk] = maps
            chunkPeaks[chunk] = (0..<maps.frames).map { frame in
                var top = SIMD3<Float>(repeating: 0)
                for bin in 0..<CFP.binCount {
                    let index = bin * maps.frames + frame
                    top = pointwiseMax(top, SIMD3(maps.spectrum[index], maps.gcos[index], maps.cepstrum[index]))
                }
                return SIMD3(log1p(top.x), log1p(top.y), log1p(top.z))
            }
        }
    }

    /// The largest log(1 + x) of each map over `frames`.
    private func peaks(over frames: Range<Int>) -> [Float] {
        var top = SIMD3<Float>(repeating: 0)
        for chunk in chunks(frames) {
            guard let peaks = chunkPeaks[chunk] else { continue }
            for (offset, peak) in peaks.enumerated() where frames.contains(chunk * Self.chunkFrames + offset) {
                top = pointwiseMax(top, peak)
            }
        }
        return [top.x, top.y, top.z]
    }

    /// The maps of `frames`, from the chunks; zero outside the song.
    private func maps(for frames: Range<Int>) -> CFP.Maps {
        let count = frames.count
        var result = CFP.Maps(frames: count, spectrum: [Float](repeating: 0, count: CFP.binCount * count),
                              gcos: [Float](repeating: 0, count: CFP.binCount * count),
                              cepstrum: [Float](repeating: 0, count: CFP.binCount * count))
        for chunk in chunks(frames) {
            guard let maps = chunkMaps[chunk] else { continue }
            let chunkStart = chunk * Self.chunkFrames
            let overlap = max(frames.lowerBound, chunkStart)..<min(frames.upperBound, chunkStart + maps.frames)
            guard !overlap.isEmpty else { continue }
            for bin in 0..<CFP.binCount {
                let from = bin * maps.frames + overlap.lowerBound - chunkStart
                let to = bin * count + overlap.lowerBound - frames.lowerBound
                result.spectrum.replaceSubrange(to..<(to + overlap.count), with: maps.spectrum[from..<(from + overlap.count)])
                result.gcos.replaceSubrange(to..<(to + overlap.count), with: maps.gcos[from..<(from + overlap.count)])
                result.cepstrum.replaceSubrange(to..<(to + overlap.count), with: maps.cepstrum[from..<(from + overlap.count)])
            }
        }
        return result
    }
}

/// Turns the voice's pitch at each tick into notes, a stretch at a time, carrying on across
/// stretches: notes hold while the pitch stays within 0.8 semitone, so vibrato doesn't split
/// them; unvoiced gaps of up to 3 ticks are bridged; and notes shorter than 4 ticks join the
/// note before them.
struct VocalLine {
    static let holdRange = 0.8
    static let bridgedTicks = 3
    static let shortestNote = 4

    private var current: Int?
    private var gap = 0
    private var started = false
    private var lastRaw: Int?
    /// While a short note is being replaced: what replaces it.
    private var replacement: Int??
    private var lastNote: Int?

    /// Notes for the first `count` ticks of `pitches`; the rest (at least `shortestNote`
    /// ticks, when there's audio there) are lookahead for telling a short note.
    mutating func notes(_ pitches: [Double?], count: Int) -> [Int?] {
        // Pitches into notes, before short ones join their neighbors.
        var raw: [Int?] = []
        var saved: (Int?, Int)?
        for (index, pitch) in pitches.enumerated() {
            if index == count { saved = (current, gap) }
            guard let pitch else {
                gap += 1
                raw.append(gap <= Self.bridgedTicks ? current : nil)
                if gap > Self.bridgedTicks { current = nil }
                continue
            }
            gap = 0
            if let note = current, abs(pitch - Double(note)) < Self.holdRange {
                raw.append(note)
            } else {
                current = Int(pitch.rounded())
                raw.append(current)
            }
        }
        if let saved { (current, gap) = saved }

        var notes: [Int?] = []
        for i in 0..<min(count, raw.count) {
            let note = raw[i]
            if !(started && note == lastRaw) {
                replacement = nil
                if note != nil && started {
                    var end = i
                    while end < raw.count && end - i < Self.shortestNote && raw[end] == note { end += 1 }
                    if end - i < Self.shortestNote && end < raw.count { replacement = .some(lastNote) }
                }
            }
            let out = replacement ?? note
            notes.append(out)
            started = true
            lastRaw = note
            lastNote = out
        }
        return notes
    }
}
