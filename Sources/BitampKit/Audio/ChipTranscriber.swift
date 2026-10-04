import Accelerate

/// Hears notes in recorded music, for the chiptune mode. Every `hop` samples it looks at
/// the latest stereo window and picks a lead, a chord and a bass note, and spots drum hits,
/// much as someone arranging a song for an old game console would.
///
/// The lead is the melody, usually the singer: it's taken from the center of the stereo
/// image, where vocals are mixed, and tracked with YIN, a pitch detector for one voice at a
/// time. The chord comes from what's left once the center is taken out, the instruments
/// panned to the sides, and is played as a fast arpeggio. The bass and the drums come from
/// the whole mix. The approach follows Su et al., "Automatic conversion of pop music into
/// chiptunes" (ICASSP 2017).
///
/// Runs on the audio render thread: nothing allocates after `prepare(sampleRate:)`.
final class ChipTranscriber {
    static let fftSize = 4096
    static let hop = 512
    /// A1 to C7; the bass picks from the notes up to `bassTop`.
    static let lowestNote = 33
    static let highestNote = 96
    static let bassTop = 52
    static let harmonics = 6
    /// Quieter than this, in dBFS, counts as silence.
    static let silence: Float = -50
    /// Hops a new note must last before a silent voice starts it, and before a playing
    /// voice switches to it, so voices don't warble; and the fewest hops a voice holds a
    /// note before changing it. For the lead, about 23, 23 and 46 ms, so the shortest
    /// blips are dropped but the melody keeps up; for the bass, 0, 35 and 90 ms.
    static let startAfter = [2, 1]
    static let switchAfter = [2, 3]
    static let minimumHops = [4, 8]
    /// Hops a voice must hear nothing before it stops: the lead bridges a short gap, as
    /// between two syllables.
    static let releaseAfter = [4, 3]
    /// Melodies mostly move by small steps, and a big leap is often a mistake, so the lead
    /// needs this many hops, about 46 ms, before leaping more than `leapSize` semitones.
    static let leapSize = 7
    static let leapAfter = 4
    /// How long the spectrum is smoothed over for the bass, which settles vibrato onto one note.
    static let smoothing = 0.06
    /// How long the key is judged over.
    static let keyMemory = 8.0
    /// How much quieter out-of-key notes count, once the key is known.
    static let outOfKey: Float = 0.55
    /// How much louder the note a voice is already playing counts, so it isn't dropped lightly.
    static let stickiness: Float = 1.3

    // MARK: Center

    /// How alike the channels must be at a frequency for it to count as the center: the
    /// center's share of each bin is the channels' similarity (1 when they match in level
    /// and phase, 0 when one is silent or they're unrelated) to this power.
    static let centerSharpness: Float = 8
    /// The same for the lead, which takes more of what's near the center: vocals are often
    /// doubled or widened a little.
    static let leadSharpness: Float = 3
    /// Below this share of side energy, on average, the music is taken to be mono, and the
    /// chord is heard in the whole mix instead.
    static let monoShare: Float = 0.02

    // MARK: Lead

    /// The lead's pitch is judged on the latest this many samples, about 46 ms.
    static let leadWindow = 2048
    /// C3 to C7.
    static let leadLowest = 48
    /// The band of the center the lead's pitch is judged in, in Hz: enough of a voice's
    /// harmonics to find its pitch, without the bass and the hiss.
    static let leadBand = (low: 120.0, high: 4_000.0)
    /// YIN's threshold on how unperiodic the center may be and still have a pitch. Less
    /// periodic than this and the lead is silent. Once it has a pitch, a looser threshold
    /// keeps it, so a held note doesn't flicker.
    static let voicingThreshold: Float = 0.2
    static let keepVoicing: Float = 0.35
    /// How much shallower than YIN's deepest dip an earlier dip may be and still be taken as
    /// the period.
    static let dipTolerance: Float = 0.15
    /// How much a dip's depth counts against a jump of an octave or more from the last pitch,
    /// when choosing among dips.
    static let jumpCost: Float = 0.2
    /// How many of the bass's harmonics are taken out of the center before its pitch is
    /// judged.
    static let bassNotch = 4
    static let notchSpread = 3
    /// The center's least share of the energy in `leadBand` for the lead to start, and to
    /// keep playing. Pitches heard in a faint center are mostly other instruments.
    static let leadShare: Float = 0.25
    static let keepShare: Float = 0.1
    /// How many hops the lead's pitch is median-smoothed over, about 58 ms. More than half
    /// of them must have a pitch for the lead to play.
    static let leadMedian = 5
    /// How far, in semitones, the lead's pitch may stray from its note before it changes, so
    /// vibrato stays on one note.
    static let leadHysteresis = 0.8
    /// A jump bigger than this, in semitones, from one hop to the next is taken as YIN
    /// hearing the wrong octave, and is folded back by octaves, unless the new pitch lasts
    /// `octaveTrust` hops.
    static let octaveJump = 9.0
    static let octaveTrust = 6

    // MARK: Chord

    /// The notes the chord is heard from: A2 to C6.
    static let chordRange = 45...84
    /// Where the arpeggio puts the chord's root, G3 to F#4, with its third and fifth above.
    static let chordRoots = 55...66
    /// How long the side spectrum is smoothed over, since chords change slowly.
    static let chordSmoothing = 0.15
    /// How many of the side's notes the chord is judged from, and how strong the others
    /// must be against the first.
    static let chordNotes = 4
    static let chordOthers: Float = 0.3
    /// How much of those notes' strength a triad must cover. Below this the arpeggio is
    /// silent rather than guess.
    static let chordMatch: Float = 0.7
    /// How strong the side's strongest note must be, against the strongest in the whole mix.
    static let chordFloor: Float = 0.1
    /// How much more a triad counts when its root is among the notes heard.
    static let chordRootHeard: Float = 1.05
    /// How much a chord out of the key counts, and how much more the current chord counts.
    static let chordOutOfKey: Float = 0.9
    static let chordStickiness: Float = 1.15
    /// The arpeggio's volume against the music's.
    static let chordVolume: Float = 0.8
    /// Hops a new chord must last before the arpeggio switches to it, and the fewest hops it
    /// plays a chord: about 70 and 280 ms.
    static let chordSwitchAfter = 6
    /// Hops the arpeggio must hear no chord before it stops, about 140 ms.
    static let chordReleaseAfter = 12
    static let chordMinimumHops = 24

    struct Voice: Equatable {
        /// A MIDI note number, or nil when the voice is silent.
        var note: Int?
        /// 0...15, like the volume of a console's sound chip.
        var level: Int
    }

    /// Up to three notes, lowest first, for the arpeggio.
    struct Chord: Equatable {
        var first: Int?
        var second: Int?
        var third: Int?
        /// 0...15.
        var level = 0

        var count: Int { first == nil ? 0 : second == nil ? 1 : third == nil ? 2 : 3 }

        subscript(index: Int) -> Int? {
            switch index {
            case 0: first
            case 1: second
            case 2: third
            default: nil
            }
        }

        func sameNotes(as other: Chord) -> Bool {
            first == other.first && second == other.second && third == other.third
        }
    }

    enum Drum: Equatable {
        case kick, snare, hat
    }

    struct Frame: Equatable {
        var lead = Voice(note: nil, level: 0)
        /// Whether the lead starts a note on this hop: a new note, or the same note sung
        /// again. The synth restarts its envelope, so repeated notes are heard.
        var onset = false
        var chord = Chord()
        var bass = Voice(note: nil, level: 0)
        /// A drum hit that started on this hop, and how loud.
        var drum: (kind: Drum, level: Int)?

        static func == (a: Frame, b: Frame) -> Bool {
            a.lead == b.lead && a.onset == b.onset && a.chord == b.chord && a.bass == b.bass
                && a.drum?.kind == b.drum?.kind && a.drum?.level == b.drum?.level
        }
    }

    /// The latest analysis.
    private(set) var frame = Frame()

    private let n = fftSize
    private let log2n = vDSP_Length(log2(Double(fftSize)))
    private let fftSetup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let leadWindowShape: UnsafeMutablePointer<Float>
    private let ringLeft: UnsafeMutablePointer<Float>
    private let ringRight: UnsafeMutablePointer<Float>
    private var ringIndex = 0
    private let windowed: UnsafeMutablePointer<Float>
    private let realLeft: UnsafeMutablePointer<Float>
    private let imaginaryLeft: UnsafeMutablePointer<Float>
    private let realRight: UnsafeMutablePointer<Float>
    private let imaginaryRight: UnsafeMutablePointer<Float>
    /// The whole mix's spectrum, as if mono.
    private let magnitude: UnsafeMutablePointer<Float>
    private let previousMagnitude: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    /// The center's spectrum, log-scaled, last hop's, for spotting the lead's onsets.
    private let previousCenter: UnsafeMutablePointer<Float>
    private let center: UnsafeMutablePointer<Float>
    /// What isn't the center: the instruments panned to the sides, smoothed.
    private let side: UnsafeMutablePointer<Float>
    private let smoothedSide: UnsafeMutablePointer<Float>
    /// The spectrum notes are picked from; overtones are taken out of it as notes are found.
    private let work: UnsafeMutablePointer<Float>
    private let salience: UnsafeMutablePointer<Float>
    /// Salience of the whole mix before any overtones were subtracted.
    private let original: UnsafeMutablePointer<Float>
    private static let noteCount = highestNote - lowestNote + 1
    /// FFT bin ranges for each note's harmonics: (start, end) pairs, note-major.
    private let bins: UnsafeMutablePointer<Int>
    private var binWidth = 44_100.0 / Double(fftSize)
    private var sampleRate = 44_100.0

    // YIN: the autocorrelation of the center, the window's own autocorrelation to divide
    // out, and the cumulative mean normalized difference.
    private let autocorrelation: UnsafeMutablePointer<Float>
    private let windowCorrelation: UnsafeMutablePointer<Float>
    private let difference: UnsafeMutablePointer<Float>
    /// The lags of the dips YIN considers, as it finds them.
    private let dips: UnsafeMutablePointer<Int>
    private static let maximumDips = 32
    private var shortestLag = 20
    private var longestLag = 401
    private var leadBins = (low: 12, high: 372)

    // The lead's pitch over the last `leadMedian` hops (NaN when there was none), a scratch
    // copy for the median, and the last pitch for octave correction.
    private let pitchHistory: UnsafeMutablePointer<Double>
    private let pitchScratch: UnsafeMutablePointer<Double>
    private var pitchIndex = 0
    private var lastPitch = Double.nan
    /// Whether the center had a pitch last hop.
    private var voiced = false
    private var lastPitchAge = 0
    private var octaveDoubt = 0

    // Per-voice switching state for the lead and the bass: the note being considered and
    // for how many hops, and how long the current note has played.
    private var pending: [(note: Int?, hops: Int)] = Array(repeating: (nil, 0), count: 2)
    private var held = [0, 0]
    private var pendingChord = Chord()
    private var pendingChordHops = 0
    private var chordHeld = 0

    // The key: how much each pitch class has sounded lately, and the notes of the key it
    // suggests as bits by pitch class, once enough music has been heard.
    private var chroma = [Float](repeating: 0, count: 12)
    /// This hop's pitch classes at the side, for the chord.
    private var chordChroma = [Float](repeating: 0, count: 12)
    private var keyScale: UInt16 = 0xfff
    private var heardHops = 0
    private var smoothingFactor: Float = 0.8
    private var chordFactor: Float = 0.9
    private var keyFactor: Float = 0.999
    /// The side's share of the energy, averaged over a few seconds.
    private var sideShare: Float = 0
    private var sideFactor: Float = 0.99

    // Drum detection: a running average of spectral flux per band, and a cooldown.
    private var fluxAverage: (kick: Float, snare: Float, hat: Float) = (0, 0, 0)
    private var drumCooldown = 0
    // Lead onsets: the same for the center's flux.
    private var centerFluxAverage: Float = 0
    private var onsetCooldown = 0
    private var onsetBins = (low: 14, high: 557)

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        window = buffer(n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        leadWindowShape = buffer(Self.leadWindow)
        vDSP_hann_window(leadWindowShape, vDSP_Length(Self.leadWindow), Int32(vDSP_HANN_NORM))
        ringLeft = buffer(n)
        ringRight = buffer(n)
        windowed = buffer(n)
        realLeft = buffer(n / 2)
        imaginaryLeft = buffer(n / 2)
        realRight = buffer(n / 2)
        imaginaryRight = buffer(n / 2)
        magnitude = buffer(n / 2)
        previousMagnitude = buffer(n / 2)
        smoothed = buffer(n / 2)
        previousCenter = buffer(n / 2)
        center = buffer(n / 2)
        side = buffer(n / 2)
        smoothedSide = buffer(n / 2)
        work = buffer(n / 2)
        salience = buffer(Self.noteCount)
        original = buffer(Self.noteCount)
        autocorrelation = buffer(n)
        windowCorrelation = buffer(n)
        difference = buffer(n)
        bins = .allocate(capacity: Self.noteCount * Self.harmonics * 2)
        pitchHistory = .allocate(capacity: Self.leadMedian)
        dips = .allocate(capacity: Self.maximumDips)
        pitchScratch = .allocate(capacity: Self.leadMedian)
        prepare(sampleRate: 44_100)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        for pointer in [window, leadWindowShape, ringLeft, ringRight, windowed, realLeft, imaginaryLeft,
                        realRight, imaginaryRight, magnitude, previousMagnitude, smoothed, previousCenter,
                        center, side, smoothedSide, work, salience, original, autocorrelation,
                        windowCorrelation, difference] {
            pointer.deallocate()
        }
        bins.deallocate()
        pitchHistory.deallocate()
        pitchScratch.deallocate()
        dips.deallocate()
    }

    /// Sets the sample rate and forgets what it heard. Not for the render thread.
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
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
        shortestLag = max(2, Int(sampleRate / Self.frequency(of: Self.highestNote)))
        longestLag = min(Self.leadWindow - 2, Int(sampleRate / Self.frequency(of: Self.leadLowest)) + 1)
        leadBins = (max(1, Int(Self.leadBand.low / binWidth)), min(n / 2 - 1, Int(Self.leadBand.high / binWidth)))
        onsetBins = (max(1, Int(150 / binWidth)), min(n / 2 - 1, Int(6_000 / binWidth)))
        measureWindowCorrelation()

        ringLeft.update(repeating: 0, count: n)
        ringRight.update(repeating: 0, count: n)
        previousMagnitude.update(repeating: 0, count: n / 2)
        smoothed.update(repeating: 0, count: n / 2)
        previousCenter.update(repeating: 0, count: n / 2)
        smoothedSide.update(repeating: 0, count: n / 2)
        pitchHistory.initialize(repeating: .nan, count: Self.leadMedian)
        pitchScratch.initialize(repeating: 0, count: Self.leadMedian)
        pitchIndex = 0
        lastPitch = .nan
        voiced = false
        lastPitchAge = 0
        octaveDoubt = 0
        ringIndex = 0
        frame = Frame()
        pending = Array(repeating: (nil, 0), count: 2)
        held = [0, 0]
        pendingChord = Chord()
        pendingChordHops = 0
        chordHeld = 0
        chroma = [Float](repeating: 0, count: 12)
        keyScale = 0xfff
        heardHops = 0
        let hopSeconds = Double(Self.hop) / sampleRate
        smoothingFactor = Float(exp(-hopSeconds / Self.smoothing))
        chordFactor = Float(exp(-hopSeconds / Self.chordSmoothing))
        keyFactor = Float(exp(-hopSeconds / Self.keyMemory))
        sideFactor = Float(exp(-hopSeconds / 3))
        sideShare = 0.1
        fluxAverage = (0, 0, 0)
        drumCooldown = 0
        centerFluxAverage = 0
        onsetCooldown = 0
    }

    static func frequency(of note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    /// Adds stereo samples to the analysis window.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let chunk = min(count - done, n - ringIndex)
            (ringLeft + ringIndex).update(from: left + done, count: chunk)
            (ringRight + ringIndex).update(from: right + done, count: chunk)
            ringIndex = (ringIndex + chunk) % n
            done += chunk
        }
    }

    /// Adds mono samples to the analysis window, as both channels.
    func push(_ samples: UnsafePointer<Float>, count: Int) {
        push(left: samples, right: samples, count: count)
    }

    /// Looks at the latest window and updates `frame`.
    func analyze() {
        spectrum()
        let loudness = self.loudness()
        let base = loudness > Self.silence ? Int((15 * min(1, (loudness - Self.silence) / 40)).rounded()) : 0

        // Drums and onsets use the raw spectrum, since they're about sudden change.
        let drum = drumHit(level: base)
        previousMagnitude.update(from: magnitude, count: n / 2)
        let onset = centerOnset()

        // Notes use smoothed ones, so vibrato and reverb settle onto one note.
        smooth(smoothed, toward: magnitude, keeping: smoothingFactor)
        smooth(smoothedSide, toward: side, keeping: chordFactor)

        work.update(from: smoothed, count: n / 2)
        computeSalience()
        original.update(from: salience, count: Self.noteCount)
        var strongest: Float = 0
        vDSP_maxv(salience, 1, &strongest, vDSP_Length(Self.noteCount))
        let quiet = base == 0 || strongest <= 0
        if !quiet { learnKey() }

        let bass = quiet ? nil : best(in: Self.lowestNote...Self.bassTop, above: strongest * 0.2,
                                      current: frame.bass.note, avoiding: 0)
        let pitch = quiet ? nil : leadPitch(without: bass)
        let lead = leadNote(pitch, current: frame.lead.note)
        let chord = quiet ? Chord() : hearChord(strongest: strongest, base: base, bass: bass, lead: lead)

        func level(_ note: Int?) -> Int {
            guard let note, strongest > 0 else { return 0 }
            let share = min(1, original[note - Self.lowestNote] / strongest)
            return max(1, Int((Float(base) * share.squareRoot()).rounded()))
        }

        var next = frame
        next.lead = settle(0, current: frame.lead, heard: lead, level: max(1, base))
        next.onset = next.lead.note != nil && (next.lead.note != frame.lead.note || onset)
        next.chord = settleChord(chord)
        next.bass = settle(1, current: frame.bass, heard: bass, level: level(bass))
        next.drum = drum
        frame = next
    }

    // MARK: - Spectra

    /// Windows the latest `count` samples of `ring`, oldest first, into `windowed`, followed
    /// by zeros, and transforms them into `real` and `imaginary`.
    private func transform(_ ring: UnsafeMutablePointer<Float>, count: Int, shape: UnsafeMutablePointer<Float>,
                           real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>) {
        let start = (ringIndex - count + n) % n
        let first = min(count, n - start)
        vDSP_vmul(ring + start, 1, shape, 1, windowed, 1, vDSP_Length(first))
        if first < count {
            vDSP_vmul(ring, 1, shape + first, 1, windowed + first, 1, vDSP_Length(count - first))
        }
        if count < n { (windowed + count).update(repeating: 0, count: n - count) }
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    /// How much of a bin is the center: 1 when both channels have it alike, in level and
    /// in phase, falling toward 0 as they differ.
    @inline(__always)
    private static func centerShare(_ lr: Float, _ li: Float, _ rr: Float, _ ri: Float,
                                    sharpness: Float = centerSharpness) -> (share: Float, power: Float) {
        let power = lr * lr + li * li + rr * rr + ri * ri
        guard power > 1e-20 else { return (0, 0) }
        let similarity = max(0, 2 * (lr * rr + li * ri) / power)
        return (pow(similarity, sharpness), power)
    }

    /// Fills `magnitude` with the whole mix's spectrum, and splits it into `center` and
    /// `side`.
    private func spectrum() {
        transform(ringLeft, count: n, shape: window, real: realLeft, imaginary: imaginaryLeft)
        transform(ringRight, count: n, shape: window, real: realRight, imaginary: imaginaryRight)
        // A full-scale sine reads about 1, as it would through one channel's spectrum.
        let scale = Float(2) / Float(n)
        var sideEnergy: Float = 0, total: Float = 0
        for k in 1..<n / 2 {
            let lr = realLeft[k], li = imaginaryLeft[k], rr = realRight[k], ri = imaginaryRight[k]
            let mr = lr + rr, mi = li + ri
            magnitude[k] = (mr * mr + mi * mi).squareRoot() * scale
            let (share, power) = Self.centerShare(lr, li, rr, ri)
            center[k] = share * magnitude[k]
            // The side keeps both channels' energy, so even out-of-phase parts are heard.
            let both = (power * 2).squareRoot() * scale
            side[k] = (1 - share) * both
            sideEnergy += side[k] * side[k]
            total += both * both
        }
        magnitude[0] = 0  // DC and Nyquist share bin 0.
        center[0] = 0
        side[0] = 0
        if total > 1e-12 {
            sideShare = sideShare * sideFactor + sideEnergy / total * (1 - sideFactor)
        }
    }

    private func smooth(_ smoothed: UnsafeMutablePointer<Float>, toward raw: UnsafeMutablePointer<Float>, keeping: Float) {
        var keep = keeping, take = 1 - keeping
        vDSP_vsmul(smoothed, 1, &keep, smoothed, 1, vDSP_Length(n / 2))
        vDSP_vsma(raw, 1, &take, smoothed, 1, smoothed, 1, vDSP_Length(n / 2))
    }

    /// The level of the latest hop, in dBFS.
    private func loudness() -> Float {
        var sum: Float = 0
        var index = (ringIndex - Self.hop + n) % n
        for _ in 0..<Self.hop {
            let mono = (ringLeft[index] + ringRight[index]) * 0.5
            sum += mono * mono
            index = index + 1 == n ? 0 : index + 1
        }
        let meanSquare = sum / Float(Self.hop)
        return 10 * log10(max(meanSquare, 1e-12)) + 3  // +3 dB so a sine's peak reads 0.
    }

    // MARK: - Lead

    /// The autocorrelation of the lead's window, which every autocorrelation it measures is
    /// divided by, so long lags aren't unfairly weak (Boersma's correction).
    private func measureWindowCorrelation() {
        windowed.update(repeating: 0, count: n)
        windowed.update(from: leadWindowShape, count: Self.leadWindow)
        var split = DSPSplitComplex(realp: realLeft, imagp: imaginaryLeft)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        autocorrelate(into: windowCorrelation, keeping: 0..<n / 2)
        let zero = max(windowCorrelation[0], 1e-20)
        for lag in 0..<n { windowCorrelation[lag] = max(windowCorrelation[lag] / zero, 1e-6) }
    }

    /// Turns the spectrum in `realLeft` and `imaginaryLeft` into its power in the bins of
    /// `band`, nothing elsewhere, and transforms that back into an autocorrelation.
    private func autocorrelate(into output: UnsafeMutablePointer<Float>, keeping band: Range<Int>) {
        for k in 1..<n / 2 {
            let power = band.contains(k) ? realLeft[k] * realLeft[k] + imaginaryLeft[k] * imaginaryLeft[k] : 0
            realLeft[k] = power
            imaginaryLeft[k] = 0
        }
        realLeft[0] = band.contains(0) ? realLeft[0] * realLeft[0] : 0
        imaginaryLeft[0] = 0
        var split = DSPSplitComplex(realp: realLeft, imagp: imaginaryLeft)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        output.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
        }
    }

    /// The pitch of the center's latest `leadWindow` samples as a fractional MIDI note, by
    /// YIN, or nil when it isn't clearly one pitch or the center is too quiet. The bass is
    /// mostly in the center too, so its lower harmonics are taken out first.
    private func leadPitch(without bass: Int?) -> Double? {
        let wasVoiced = voiced
        let threshold = voiced ? Self.keepVoicing : Self.voicingThreshold
        voiced = false
        transform(ringLeft, count: Self.leadWindow, shape: leadWindowShape, real: realLeft, imaginary: imaginaryLeft)
        transform(ringRight, count: Self.leadWindow, shape: leadWindowShape, real: realRight, imaginary: imaginaryRight)
        // The center, in the lead's band, into the left channel's buffers.
        var centerPower: Float = 0, total: Float = 0
        for k in leadBins.low...leadBins.high {
            let lr = realLeft[k], li = imaginaryLeft[k], rr = realRight[k], ri = imaginaryRight[k]
            let (share, power) = Self.centerShare(lr, li, rr, ri, sharpness: Self.leadSharpness)
            realLeft[k] = (lr + rr) * 0.5 * share
            imaginaryLeft[k] = (li + ri) * 0.5 * share
            centerPower += realLeft[k] * realLeft[k] + imaginaryLeft[k] * imaginaryLeft[k]
            total += power * 0.5
        }
        guard total > 1e-12, centerPower / total >= (wasVoiced ? Self.keepShare : Self.leadShare) else { return nil }
        if let bass {
            for h in 0..<Self.bassNotch {
                let index = ((bass - Self.lowestNote) * Self.harmonics + h) * 2
                // Wider than the note's own bins: this window is half as long, so its
                // harmonics are twice as wide.
                for k in max(0, bins[index] - Self.notchSpread)..<min(n / 2, bins[index + 1] + Self.notchSpread) {
                    realLeft[k] = 0
                    imaginaryLeft[k] = 0
                }
            }
        }
        autocorrelate(into: autocorrelation, keeping: leadBins.low..<leadBins.high + 1)
        let zero = autocorrelation[0]
        guard zero > 0 else { return nil }

        // YIN's cumulative mean normalized difference, from the windowed autocorrelation.
        var runningSum: Float = 0
        for lag in 1...longestLag {
            let correlation = autocorrelation[lag] / zero / windowCorrelation[lag]
            let d = max(0, 2 * (1 - correlation))
            runningSum += d
            difference[lag] = runningSum > 0 ? d * Float(lag) / runningSum : 1
        }
        // Periodic enough if the deepest dip is under the threshold.
        var deepest: Float = 1
        for lag in shortestLag..<longestLag { deepest = min(deepest, difference[lag]) }
        guard deepest < threshold else { return nil }
        voiced = true
        // Each dip nearly as deep as the deepest could be the period: a note dips again at
        // twice its period, and a harmonic or another instrument may dip almost as low. As in
        // pYIN, prefer the one nearest the last pitch; with none, the shortest.
        let recent = !lastPitch.isNaN && lastPitchAge <= 4
        // A dip at a multiple of an earlier one is that note again, an octave or more down.
        var lag = 0
        var bestCost = Float.infinity
        var found = 0
        candidates: for candidate in shortestLag + 1..<longestLag - 1 {
            let value = difference[candidate]
            guard value <= deepest + Self.dipTolerance, value <= difference[candidate - 1],
                  value < difference[candidate + 1] else { continue }
            for i in 0..<found {
                let ratio = Double(candidate) / Double(dips[i])
                if ratio > 1.5 && abs(ratio - ratio.rounded()) < 0.06 { continue candidates }
            }
            if found < Self.maximumDips {
                dips[found] = candidate
                found += 1
            }
            var cost = value
            if recent {
                let pitch = 69 + 12 * log2(sampleRate / Double(candidate) / 440)
                cost += Self.jumpCost * Float(min(12, abs(pitch - lastPitch))) / 12
            } else if lag > 0 {
                break
            }
            if cost < bestCost {
                bestCost = cost
                lag = candidate
            }
        }
        guard lag > 0 else {
            voiced = false
            return nil
        }
        // A parabola through the dip finds the period between samples.
        let a = difference[lag - 1], b = difference[lag], c = difference[lag + 1]
        let bend = a - 2 * b + c
        let offset = bend > 0 ? Double(0.5 * (a - c) / bend) : 0
        let period = Double(lag) + max(-0.5, min(0.5, offset))
        return 69 + 12 * log2(sampleRate / period / 440)
    }

    /// Folds a pitch that leapt more than `octaveJump` from the last one back toward it by
    /// octaves, as such leaps are mostly YIN mistaking the octave; a leap that holds for
    /// `octaveTrust` hops is believed.
    private func correctOctave(_ pitch: Double) -> Double {
        guard !lastPitch.isNaN, lastPitchAge <= 16 else {
            octaveDoubt = 0
            return pitch
        }
        var folded = pitch
        while folded - lastPitch > Self.octaveJump { folded -= 12 }
        while lastPitch - folded > Self.octaveJump { folded += 12 }
        // Only whole octaves, give or take a semitone, are YIN's kind of mistake.
        if abs(folded - lastPitch) > 1 { folded = pitch }
        if folded == pitch {
            octaveDoubt = 0
            return pitch
        }
        octaveDoubt += 1
        if octaveDoubt >= Self.octaveTrust {
            octaveDoubt = 0
            return pitch
        }
        return folded
    }

    /// The lead's note from this hop's pitch: octave-corrected, median-smoothed over the
    /// last hops, and rounded to a semitone, staying on `current` through vibrato and
    /// leaning toward the key.
    private func leadNote(_ raw: Double?, current: Int?) -> Int? {
        var pitch = Double.nan
        if let raw {
            pitch = correctOctave(raw)
            lastPitch = pitch
            lastPitchAge = 0
        } else {
            lastPitchAge += 1
        }
        pitchHistory[pitchIndex] = pitch
        pitchIndex = (pitchIndex + 1) % Self.leadMedian

        // The median of the hops that had a pitch, if most did.
        var voiced = 0
        for i in 0..<Self.leadMedian where !pitchHistory[i].isNaN {
            // Insertion sort into the scratch space; there are only a few.
            var j = voiced
            while j > 0 && pitchScratch[j - 1] > pitchHistory[i] {
                pitchScratch[j] = pitchScratch[j - 1]
                j -= 1
            }
            pitchScratch[j] = pitchHistory[i]
            voiced += 1
        }
        guard voiced * 2 > Self.leadMedian else { return nil }
        let median = pitchScratch[voiced / 2]

        if let current, abs(median - Double(current)) < Self.leadHysteresis { return current }
        var note = Int(median.rounded())
        // Between two notes, prefer the one in the key.
        if keyScale & (1 << UInt16(note % 12)) == 0 {
            let other = median > Double(note) ? note + 1 : note - 1
            if keyScale & (1 << UInt16(other % 12)) != 0 && abs(median - Double(other)) < 0.75 { note = other }
        }
        return min(Self.highestNote, max(Self.leadLowest, note))
    }

    /// Whether the center suddenly got louder across many frequencies, as when a new
    /// syllable is sung, even on the same note. A note fading or wavering moves energy
    /// between frequencies too, but doesn't make the whole louder.
    private func centerOnset() -> Bool {
        var flux: Float = 0, now: Float = 0, before: Float = 0
        for k in onsetBins.low...onsetBins.high {
            let level = log1p(100 * center[k])
            flux += max(0, level - previousCenter[k])
            let previous = expm1(previousCenter[k]) / 100
            now += center[k] * center[k]
            before += previous * previous
            previousCenter[k] = level
        }
        defer { centerFluxAverage = centerFluxAverage * 0.9 + flux * 0.1 }
        if onsetCooldown > 0 {
            onsetCooldown -= 1
            return false
        }
        guard flux > 2 * centerFluxAverage && flux > 3 && now > before * 1.15 else { return false }
        onsetCooldown = 6
        return true
    }

    // MARK: - Notes

    /// How strongly each note sounds in `work`: its harmonics, weighted toward the
    /// fundamental. A note whose fundamental is missing is mostly an octave-below ghost of a
    /// real note, so it's scaled down.
    private func computeSalience() {
        for note in 0..<Self.noteCount {
            var total: Float = 0
            var weight: Float = 1
            var fundamental: Float = 0
            var loudest: Float = 0
            for h in 0..<Self.harmonics {
                let index = (note * Self.harmonics + h) * 2
                var peak: Float = 0
                vDSP_maxv(work + bins[index], 1, &peak, vDSP_Length(bins[index + 1] - bins[index]))
                if h == 0 { fundamental = peak }
                loudest = max(loudest, peak)
                total += weight * peak
                weight *= 0.75
            }
            salience[note] = loudest > 0 ? total * min(1, 2 * fundamental / loudest) : 0
        }
    }

    private static func bit(_ note: Int) -> UInt64 {
        let i = note - lowestNote
        return (0..<noteCount).contains(i) ? 1 << UInt64(i) : 0
    }

    /// Lowers `work` at `note`'s harmonics by what the note itself likely put there: at
    /// most its fundamental, falling off for higher harmonics. Whatever is louder than that
    /// is probably another note, and stays. Then recomputes salience.
    private func subtractOvertones(of note: Int) {
        let i = note - Self.lowestNote
        var fundamental: Float = 0
        var expected: Float = 0
        for h in 0..<Self.harmonics {
            let index = (i * Self.harmonics + h) * 2
            let start = bins[index], count = bins[index + 1] - bins[index]
            var peak: Float = 0
            vDSP_maxv(work + start, 1, &peak, vDSP_Length(count))
            if h == 0 {
                fundamental = peak
                expected = peak
            } else {
                expected = fundamental * pow(0.7, Float(h))
            }
            var amount = -min(peak, expected)
            vDSP_vsadd(work + start, 1, &amount, work + start, 1, vDSP_Length(count))
            var zero: Float = 0
            vDSP_vthr(work + start, 1, &zero, work + start, 1, vDSP_Length(count))
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

    /// The accompaniment's chord, as the major or minor triad that best matches the pitch
    /// classes at the side of the stereo image (or, when the music is mono, in the whole
    /// mix without the bass and the lead), voiced around middle C for the arpeggio. Silent
    /// when nothing matches clearly, rather than a guess.
    private func hearChord(strongest: Float, base: Int, bass: Int?, lead: Int?) -> Chord {
        if sideShare < Self.monoShare {
            work.update(from: smoothed, count: n / 2)
            computeSalience()
            if let bass { subtractOvertones(of: bass) }
            if let lead { subtractOvertones(of: lead) }
        } else {
            work.update(from: smoothedSide, count: n / 2)
            computeSalience()
        }
        // The clearest few notes, each one's overtones taken out before the next.
        for i in 0..<12 { chordChroma[i] = 0 }
        var total: Float = 0, loudest: Float = 0
        var floor = strongest * Self.chordFloor
        var avoiding: UInt64 = 0
        for _ in 0..<Self.chordNotes {
            guard let note = best(in: Self.chordRange, above: floor, current: nil, avoiding: avoiding) else { break }
            let strength = salience[note - Self.lowestNote]
            if loudest == 0 {
                loudest = strength
                floor = max(floor, strength * Self.chordOthers)
            }
            chordChroma[note % 12] += strength
            total += strength
            avoiding |= Self.bit(note)
            subtractOvertones(of: note)
        }
        guard total > 0 else { return Chord() }

        // The major or minor triad that covers most of them, by strength, with at least two
        // of its notes heard. In the key and the current chord count for a little more.
        let currentRoot = frame.chord.first.map { $0 % 12 } ?? -1
        let currentMinor = frame.chord.second.map { $0 - frame.chord.first! == 3 } ?? false
        var bestScore = Self.chordMatch
        var bestRoot = -1, bestMinor = false
        for root in 0..<12 {
            for mode in 0..<2 {
                let minor = mode == 1
                let third = (root + (minor ? 3 : 4)) % 12, fifth = (root + 7) % 12
                let heard = (chordChroma[root] > 0 ? 1 : 0) + (chordChroma[third] > 0 ? 1 : 0)
                    + (chordChroma[fifth] > 0 ? 1 : 0)
                guard heard >= 2 else { continue }
                var score = (chordChroma[root] + chordChroma[third] + chordChroma[fifth]) / total
                let inKey = keyScale & (1 << UInt16(root)) != 0 && keyScale & (1 << UInt16(third)) != 0
                    && keyScale & (1 << UInt16(fifth)) != 0
                if !inKey { score *= Self.chordOutOfKey }
                if chordChroma[root] > 0 { score *= Self.chordRootHeard }
                if root == currentRoot && minor == currentMinor { score *= Self.chordStickiness }
                guard score > bestScore else { continue }
                bestScore = score
                bestRoot = root
                bestMinor = minor
            }
        }
        guard bestRoot >= 0 else { return Chord() }
        let low = Self.chordRoots.lowerBound
        let root = low + ((bestRoot - low) % 12 + 12) % 12
        let level = max(1, Int((Float(base) * Self.chordVolume * min(1, loudest / strongest).squareRoot()).rounded()))
        return Chord(first: root, second: root + (bestMinor ? 3 : 4), third: root + 7, level: level)
    }

    /// Keeps a voice on its note until a different one has lasted `switchAfter` hops and the
    /// current one has played its minimum length. A voice that was silent starts once a
    /// note has lasted `startAfter` hops.
    private func settle(_ voice: Int, current: Voice, heard: Int?, level: Int) -> Voice {
        if current.note == nil && heard != nil && Self.startAfter[voice] > 1 {
            if pending[voice].note == heard {
                pending[voice].hops += 1
            } else {
                pending[voice] = (heard, 1)
            }
            guard pending[voice].hops >= Self.startAfter[voice] else { return current }
        }
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
        var needed = heard == nil ? Self.releaseAfter[voice] : Self.switchAfter[voice]
        if voice == 0, let heard, let note = current.note, abs(heard - note) > Self.leapSize { needed = Self.leapAfter }
        if pending[voice].hops >= needed && held[voice] >= Self.minimumHops[voice] {
            pending[voice] = (nil, 0)
            held[voice] = 0
            return Voice(note: heard, level: heard == nil ? 0 : level)
        }
        return current
    }

    /// Keeps the arpeggio on its chord until a different one has lasted `chordSwitchAfter`
    /// hops and the current one has played `chordMinimumHops`. Starting from silence takes
    /// only half as long.
    private func settleChord(_ heard: Chord) -> Chord {
        chordHeld += 1
        var current = frame.chord
        if heard.sameNotes(as: current) {
            pendingChordHops = 0
            current.level = heard.level
            return current
        }
        if heard.sameNotes(as: pendingChord) {
            pendingChordHops += 1
        } else {
            pendingChord = heard
            pendingChordHops = 1
        }
        let fromSilence = current.count == 0
        let needed = fromSilence ? Self.chordSwitchAfter / 2 : heard.count == 0 ? Self.chordReleaseAfter : Self.chordSwitchAfter
        guard pendingChordHops >= needed && (fromSilence || chordHeld >= Self.chordMinimumHops) else { return current }
        pendingChordHops = 0
        chordHeld = 0
        return heard
    }

    // MARK: - Key

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

    // MARK: - Drums

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
