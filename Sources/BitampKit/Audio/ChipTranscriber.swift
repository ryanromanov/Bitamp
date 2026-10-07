import Accelerate

/// Hears notes in recorded music, for the chiptune mode. Every `hop` samples it looks at
/// the spectrum and picks a lead, a harmony and a bass note, and spots drum hits, much as
/// someone arranging a song for an old game console would.
///
/// Runs on the audio render thread: nothing allocates after `prepare(sampleRate:)`.
final class ChipTranscriber {
    static let fftSize = 4096
    static let hop = 512
    /// A1 to C7; the bass picks from the notes up to `bassTop`, the others from above it.
    static let lowestNote = 33
    static let highestNote = 96
    static let bassTop = 52
    static let harmonics = 6
    /// Quieter than this, in dBFS, counts as silence.
    static let silence: Float = -50
    /// Hops a new note must last before a voice switches to it, so voices don't warble.
    static let switchAfter = 3
    /// The fewest hops each voice (lead, harmony, bass) holds a note before changing it:
    /// about 70, 140 and 90 ms.
    static let minimumHops = [6, 12, 8]
    /// How long the spectrum is smoothed over, which settles vibrato onto one note.
    static let smoothing = 0.06
    /// How long the key is judged over.
    static let keyMemory = 8.0
    /// How much quieter out-of-key notes count, once the key is known.
    static let outOfKey: Float = 0.55
    /// How much louder the note a voice is already playing counts, so it isn't dropped lightly.
    static let stickiness: Float = 1.3

    struct Voice: Equatable {
        /// A MIDI note number, or nil when the voice is silent.
        var note: Int?
        /// 0...15, like the volume of a console's sound chip.
        var level: Int
    }

    enum Drum: Equatable {
        case kick, snare, hat
    }

    struct Frame: Equatable {
        var lead = Voice(note: nil, level: 0)
        var harmony = Voice(note: nil, level: 0)
        var bass = Voice(note: nil, level: 0)
        /// A drum hit that started on this hop, and how loud.
        var drum: (kind: Drum, level: Int)?

        static func == (a: Frame, b: Frame) -> Bool {
            a.lead == b.lead && a.harmony == b.harmony && a.bass == b.bass
                && a.drum?.kind == b.drum?.kind && a.drum?.level == b.drum?.level
        }
    }

    /// The latest analysis.
    private(set) var frame = Frame()

    private let n = fftSize
    private let log2n = vDSP_Length(log2(Double(fftSize)))
    private let fftSetup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private var ringIndex = 0
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let magnitude: UnsafeMutablePointer<Float>
    private let previousMagnitude: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    private let salience: UnsafeMutablePointer<Float>
    /// Salience before any overtones were subtracted.
    private let original: UnsafeMutablePointer<Float>
    private static let noteCount = highestNote - lowestNote + 1
    /// FFT bin ranges for each note's harmonics: (start, end) pairs, note-major.
    private let bins: UnsafeMutablePointer<Int>
    private var binWidth = 44_100.0 / Double(fftSize)

    // Per-voice switching state: the note being considered and for how many hops, and how
    // long the current note has played.
    private var pending: [(note: Int?, hops: Int)] = Array(repeating: (nil, 0), count: 3)
    private var held = [0, 0, 0]

    // The key: how much each pitch class has sounded lately, and the notes of the key it
    // suggests as bits by pitch class, once enough music has been heard.
    private var chroma = [Float](repeating: 0, count: 12)
    private var keyScale: UInt16 = 0xfff
    private var heardHops = 0
    private var smoothingFactor: Float = 0.8
    private var keyFactor: Float = 0.999

    // Drum detection: a running average of spectral flux per band, and a cooldown.
    private var fluxAverage: (kick: Float, snare: Float, hat: Float) = (0, 0, 0)
    private var drumCooldown = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        window = buffer(n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        ring = buffer(n)
        windowed = buffer(n)
        real = buffer(n / 2)
        imaginary = buffer(n / 2)
        magnitude = buffer(n / 2)
        previousMagnitude = buffer(n / 2)
        smoothed = buffer(n / 2)
        salience = buffer(Self.noteCount)
        original = buffer(Self.noteCount)
        bins = .allocate(capacity: Self.noteCount * Self.harmonics * 2)
        prepare(sampleRate: 44_100)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        for pointer in [window, ring, windowed, real, imaginary, magnitude, previousMagnitude, smoothed, salience, original] {
            pointer.deallocate()
        }
        bins.deallocate()
    }

    /// Sets the sample rate and forgets what it heard. Not for the render thread.
    func prepare(sampleRate: Double) {
        binWidth = sampleRate / Double(n)
        // Each harmonic's bins span half a semitone either side of it.
        let spread = pow(2, 0.5 / 12)
        for note in 0..<Self.noteCount {
            let frequency = Self.frequency(of: Self.lowestNote + note)
            for h in 0..<Self.harmonics {
                let center = frequency * Double(h + 1)
                let low = max(1, Int((center / spread / binWidth).rounded(.down)))
                let high = min(n / 2, max(low + 1, Int((center * spread / binWidth).rounded(.up))))
                let index = (note * Self.harmonics + h) * 2
                bins[index] = min(low, n / 2 - 1)
                bins[index + 1] = high
            }
        }
        ring.update(repeating: 0, count: n)
        previousMagnitude.update(repeating: 0, count: n / 2)
        smoothed.update(repeating: 0, count: n / 2)
        ringIndex = 0
        frame = Frame()
        pending = Array(repeating: (nil, 0), count: 3)
        held = [0, 0, 0]
        chroma = [Float](repeating: 0, count: 12)
        keyScale = 0xfff
        heardHops = 0
        let hopSeconds = Double(Self.hop) / sampleRate
        smoothingFactor = Float(exp(-hopSeconds / Self.smoothing))
        keyFactor = Float(exp(-hopSeconds / Self.keyMemory))
        fluxAverage = (0, 0, 0)
        drumCooldown = 0
    }

    static func frequency(of note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    /// Adds mono samples to the analysis window.
    func push(_ samples: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let chunk = min(count - done, n - ringIndex)
            (ring + ringIndex).update(from: samples + done, count: chunk)
            ringIndex = (ringIndex + chunk) % n
            done += chunk
        }
    }

    /// Looks at the latest window and updates `frame`.
    func analyze() {
        spectrum()
        let loudness = self.loudness()
        let base = loudness > Self.silence ? Int((15 * min(1, (loudness - Self.silence) / 40)).rounded()) : 0

        // Drums use the raw spectrum, since they're about sudden change.
        let drum = drumHit(level: base)
        previousMagnitude.update(from: magnitude, count: n / 2)

        // Notes use a smoothed one, so vibrato and reverb settle onto one note.
        var keep = smoothingFactor, take = 1 - smoothingFactor
        vDSP_vsmul(smoothed, 1, &keep, smoothed, 1, vDSP_Length(n / 2))
        vDSP_vsma(magnitude, 1, &take, smoothed, 1, smoothed, 1, vDSP_Length(n / 2))
        magnitude.update(from: smoothed, count: n / 2)

        computeSalience()
        original.update(from: salience, count: Self.noteCount)
        var strongest: Float = 0
        vDSP_maxv(salience, 1, &strongest, vDSP_Length(Self.noteCount))
        let quiet = base == 0 || strongest <= 0
        if !quiet { learnKey() }

        // Pick the bass, then the lead, then a harmony. After each pick, take that note's
        // overtones out of the spectrum, so they aren't heard again as notes of their own.
        let bass = quiet ? nil : best(in: Self.lowestNote...Self.bassTop, above: strongest * 0.2,
                                      current: frame.bass.note, avoiding: 0)
        if let bass { subtractOvertones(of: bass) }
        let lead = quiet ? nil : best(in: Self.bassTop + 1...Self.highestNote, above: strongest * 0.2,
                                      current: frame.lead.note, avoiding: 0)
        var harmony: Int?
        if let lead {
            let leadSalience = salience[lead - Self.lowestNote]
            subtractOvertones(of: lead)
            // Only a clear second note; a doubtful harmony is most of what sounds chaotic.
            harmony = best(in: Self.bassTop + 1...Self.highestNote, above: leadSalience * 0.55,
                           current: frame.harmony.note, avoiding: Self.bits(lead - 1, lead, lead + 1, lead))
        }

        // Levels compare each note's strength before any subtraction.
        func level(_ note: Int?, scale: Float = 1) -> Int {
            guard let note, strongest > 0 else { return 0 }
            let share = min(1, original[note - Self.lowestNote] / strongest)
            return max(1, Int((Float(base) * share.squareRoot() * scale).rounded()))
        }

        var next = frame
        next.lead = settle(0, current: frame.lead, heard: lead, level: level(lead))
        next.harmony = settle(1, current: frame.harmony, heard: harmony, level: level(harmony, scale: 0.75))
        next.bass = settle(2, current: frame.bass, heard: bass, level: level(bass))
        next.drum = drum
        frame = next
    }

    // MARK: - Steps

    /// Windows the ring, oldest sample first, and fills `magnitude` with each bin's amplitude.
    private func spectrum() {
        let older = n - ringIndex
        vDSP_vmul(ring + ringIndex, 1, window, 1, windowed, 1, vDSP_Length(older))
        if ringIndex > 0 {
            vDSP_vmul(ring, 1, window + older, 1, windowed + older, 1, vDSP_Length(ringIndex))
        }
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitude, 1, vDSP_Length(n / 2))
        magnitude[0] = 0  // DC and Nyquist share bin 0.
        // A full-scale sine reads about 1: a Hann window averages 0.5, so its peak is n / 4.
        var scale = Float(4) / Float(n)
        vDSP_vsmul(magnitude, 1, &scale, magnitude, 1, vDSP_Length(n / 2))
    }

    /// The level of the latest hop, in dBFS.
    private func loudness() -> Float {
        var meanSquare: Float = 0
        let start = (ringIndex - Self.hop + n) % n
        if start + Self.hop <= n {
            vDSP_measqv(ring + start, 1, &meanSquare, vDSP_Length(Self.hop))
        } else {
            var a: Float = 0, b: Float = 0
            let first = n - start
            vDSP_measqv(ring + start, 1, &a, vDSP_Length(first))
            vDSP_measqv(ring, 1, &b, vDSP_Length(Self.hop - first))
            meanSquare = (a * Float(first) + b * Float(Self.hop - first)) / Float(Self.hop)
        }
        return 10 * log10(max(meanSquare, 1e-12)) + 3  // +3 dB so a sine's peak reads 0.
    }

    /// How strongly each note sounds: its harmonics, weighted toward the fundamental. A note
    /// whose fundamental is missing is mostly an octave-below ghost of a real note, so it's
    /// scaled down.
    private func computeSalience() {
        for note in 0..<Self.noteCount {
            var total: Float = 0
            var weight: Float = 1
            var fundamental: Float = 0
            var loudest: Float = 0
            for h in 0..<Self.harmonics {
                let index = (note * Self.harmonics + h) * 2
                var peak: Float = 0
                vDSP_maxv(magnitude + bins[index], 1, &peak, vDSP_Length(bins[index + 1] - bins[index]))
                if h == 0 { fundamental = peak }
                loudest = max(loudest, peak)
                total += weight * peak
                weight *= 0.75
            }
            salience[note] = loudest > 0 ? total * min(1, 2 * fundamental / loudest) : 0
        }
    }

    /// A set of notes as bits, one per note from `lowestNote`; notes out of range are left out.
    /// Fixed arguments rather than an array, so nothing allocates on the render thread.
    private static func bits(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> UInt64 {
        bit(a) | bit(b) | bit(c) | bit(d)
    }

    private static func bit(_ note: Int) -> UInt64 {
        let i = note - lowestNote
        return (0..<noteCount).contains(i) ? 1 << UInt64(i) : 0
    }

    /// Lowers the spectrum at `note`'s harmonics by what the note itself likely put there:
    /// at most its fundamental, falling off for higher harmonics. Whatever is louder than
    /// that is probably another note, and stays. Then recomputes salience.
    private func subtractOvertones(of note: Int) {
        let i = note - Self.lowestNote
        var fundamental: Float = 0
        var expected: Float = 0
        for h in 0..<Self.harmonics {
            let index = (i * Self.harmonics + h) * 2
            let start = bins[index], count = bins[index + 1] - bins[index]
            var peak: Float = 0
            vDSP_maxv(magnitude + start, 1, &peak, vDSP_Length(count))
            if h == 0 {
                fundamental = peak
                expected = peak
            } else {
                expected = fundamental * pow(0.7, Float(h))
            }
            var amount = -min(peak, expected)
            vDSP_vsadd(magnitude + start, 1, &amount, magnitude + start, 1, vDSP_Length(count))
            var zero: Float = 0
            vDSP_vthr(magnitude + start, 1, &zero, magnitude + start, 1, vDSP_Length(count))
        }
        computeSalience()
    }

    /// The most salient note in `range` that's a local peak, louder than `floor`, and not
    /// one of the notes in `avoiding`. Out-of-key notes count for less, and the note the
    /// voice is already playing for more. The same note in another octave counts as the
    /// current one, since octave jumps are mostly mistakes.
    private func best(in range: ClosedRange<Int>, above floor: Float, current: Int?, avoiding: UInt64) -> Int? {
        var bestNote: Int?
        var bestValue = floor
        for note in range where avoiding & Self.bit(note) == 0 {
            let i = note - Self.lowestNote
            let raw = salience[i]
            if i > 0 && salience[i - 1] > raw { continue }
            if i < Self.noteCount - 1 && salience[i + 1] > raw { continue }
            var value = raw
            if keyScale & (1 << UInt16(note % 12)) == 0 { value *= Self.outOfKey }
            if note == current { value *= Self.stickiness }
            guard value > bestValue else { continue }
            bestNote = note
            bestValue = value
        }
        if let bestNote, let current, bestNote != current, bestNote % 12 == current % 12,
           range.contains(current), salience[current - Self.lowestNote] > bestValue * 0.25 {
            return current
        }
        return bestNote
    }

    /// Keeps a voice on its note until a different one has lasted `switchAfter` hops and the
    /// current one has played its minimum length. A voice that was silent starts at once.
    private func settle(_ voice: Int, current: Voice, heard: Int?, level: Int) -> Voice {
        if heard == current.note || (current.note == nil && heard != nil) {
            if heard != current.note { held[voice] = 0 }
            held[voice] += 1
            pending[voice] = (nil, 0)
            return Voice(note: heard, level: heard == nil ? 0 : level)
        }
        held[voice] += 1
        if pending[voice].note == heard {
            pending[voice].hops += 1
        } else {
            pending[voice] = (heard, 1)
        }
        if pending[voice].hops >= Self.switchAfter && held[voice] >= Self.minimumHops[voice] {
            pending[voice] = (nil, 0)
            held[voice] = 0
            return Voice(note: heard, level: heard == nil ? 0 : level)
        }
        return current
    }

    // Krumhansl's key profiles: how much each scale degree sounds in music in a key.
    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    /// Major, and minor with both the natural and the raised seventh, as bits from the tonic.
    private static let majorScale: UInt16 = 0b1010_1011_0101
    private static let minorScale: UInt16 = 0b1101_1010_1101

    /// Adds this hop's notes to the pitch-class history and, every so often, re-judges the
    /// key as the major or minor key whose profile matches the history best.
    private func learnKey() {
        for i in 0..<12 { chroma[i] *= keyFactor }
        for note in 0..<Self.noteCount {
            chroma[(Self.lowestNote + note) % 12] += original[note] * (1 - keyFactor)
        }
        heardHops += 1
        // About two seconds of music before trusting it, then re-judged a few times a second.
        guard heardHops >= 180, heardHops % 16 == 0 else { return }
        var mean: Float = 0
        for value in chroma { mean += value }
        mean /= 12
        var bestScore = -Float.infinity
        var scale: UInt16 = 0xfff
        for tonic in 0..<12 {
            for mode in 0..<2 {
                let minor = mode == 1
                let profile = minor ? Self.minorProfile : Self.majorProfile
                var score: Float = 0
                for degree in 0..<12 {
                    score += (chroma[(tonic + degree) % 12] - mean) * (profile[degree] - 4)
                }
                if score > bestScore {
                    bestScore = score
                    // Rotate the scale's bits up to the tonic.
                    let steps = minor ? Self.minorScale : Self.majorScale
                    scale = ((steps << UInt16(tonic)) | (steps >> UInt16(12 - tonic))) & 0xfff
                }
            }
        }
        keyScale = scale
    }

    /// A drum hit when a band's energy jumps well above its recent average.
    private func drumHit(level: Int) -> (kind: Drum, level: Int)? {
        let kick = flux(from: 40, to: 150)
        let snare = flux(from: 1_000, to: 5_000)
        let hat = flux(from: 7_000, to: 14_000)
        defer {
            fluxAverage.kick = fluxAverage.kick * 0.92 + kick * 0.08
            fluxAverage.snare = fluxAverage.snare * 0.92 + snare * 0.08
            fluxAverage.hat = fluxAverage.hat * 0.92 + hat * 0.08
        }
        if drumCooldown > 0 {
            drumCooldown -= 1
            return nil
        }
        guard level > 0 else { return nil }
        let hit: Drum?
        if kick > 2.2 * fluxAverage.kick && kick > 0.02 {
            hit = .kick
        } else if snare > 2.2 * fluxAverage.snare && snare > 0.02 {
            hit = .snare
        } else if hat > 2.2 * fluxAverage.hat && hat > 0.01 {
            hit = .hat
        } else {
            hit = nil
        }
        guard let hit else { return nil }
        drumCooldown = 4
        return (hit, level)
    }

    /// How much a band's magnitude rose since the last hop.
    private func flux(from low: Double, to high: Double) -> Float {
        let start = max(1, Int(low / binWidth)), end = min(n / 2, Int(high / binWidth))
        var total: Float = 0
        for bin in start..<max(start, end) {
            total += max(0, magnitude[bin] - previousMagnitude[bin])
        }
        return total
    }
}

