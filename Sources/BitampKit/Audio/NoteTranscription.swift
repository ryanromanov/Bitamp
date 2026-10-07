import AVFoundation
import BitampAtomics

/// What the chip plays at one moment of a song: a lead, up to three chord notes to
/// arpeggiate, and a bass, as MIDI notes (0 for none) with 4-bit volumes.
struct ChipMoment: Equatable {
    var lead: UInt8 = 0
    var chord: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var bass: UInt8 = 0
    var leadLevel: UInt8 = 0
    var chordLevel: UInt8 = 0
    var bassLevel: UInt8 = 0
    /// Voices whose note starts in this moment, as `leadOnset`, `chordOnset`, `bassOnset`.
    var onsets: UInt8 = 0

    static let leadOnset: UInt8 = 1
    static let chordOnset: UInt8 = 2
    static let bassOnset: UInt8 = 4

    static func == (a: ChipMoment, b: ChipMoment) -> Bool {
        a.lead == b.lead && a.chord == b.chord && a.bass == b.bass && a.leadLevel == b.leadLevel
            && a.chordLevel == b.chordLevel && a.bassLevel == b.bassLevel && a.onsets == b.onsets
    }
}

/// A song's chip arrangement, a `ChipMoment` for every `tickSeconds` of it, filled in by
/// `NoteTranscription` on a background thread and read by the render thread.
///
/// Each moment is written once, then marked ready with a release store; the render thread
/// checks the mark with an acquire load before reading, so it needs no locks and never
/// sees a half-written moment. Moments not yet ready read as nil.
final class ChipScore: @unchecked Sendable {
    /// One Basic Pitch frame: 256 samples at 22,050 Hz, about 11.6 ms.
    static let tickSeconds = Double(BasicPitch.fftHop) / BasicPitch.sampleRate

    let count: Int
    private let moments: UnsafeMutablePointer<ChipMoment>
    private let ready: UnsafeMutablePointer<Int32>
    /// 1 until the transcription finds it can't run, when players should hear something else.
    private let usable: UnsafeMutablePointer<Int32>
    /// The tick last asked for, which is where the playhead is.
    private let playhead: UnsafeMutablePointer<Int32>

    init(duration: Double) {
        count = max(1, Int((duration / Self.tickSeconds).rounded(.up)) + 1)
        moments = .allocate(capacity: count)
        moments.initialize(repeating: ChipMoment(), count: count)
        ready = .allocate(capacity: count)
        ready.initialize(repeating: 0, count: count)
        usable = .allocate(capacity: 1)
        usable.initialize(to: 1)
        playhead = .allocate(capacity: 1)
        playhead.initialize(to: 0)
    }

    deinit {
        moments.deallocate()
        ready.deallocate()
        usable.deallocate()
        playhead.deallocate()
    }

    /// Whether this score will ever have notes.
    var isUsable: Bool { bitamp_load_acquire_32(usable) != 0 }

    func markUnusable() { bitamp_store_release_32(usable, 0) }

    /// Writes the moment at `tick`, once; later writes to a ready tick are ignored.
    func write(_ moment: ChipMoment, at tick: Int) {
        guard tick >= 0 && tick < count, bitamp_load_acquire_32(ready + tick) == 0 else { return }
        moments[tick] = moment
        bitamp_store_release_32(ready + tick, 1)
    }

    /// The moment at `tick`, if it's been worked out. Safe on the render thread, which asks
    /// for the playhead's tick, so this also notes where the playhead is.
    func moment(at tick: Int) -> ChipMoment? {
        bitamp_store_release_32(playhead, Int32(clamping: tick))
        guard tick >= 0 && tick < count, bitamp_load_acquire_32(ready + tick) != 0 else { return nil }
        return moments[tick]
    }

    /// Whether the moment at `tick` has been worked out, without moving the playhead.
    func isWritten(at tick: Int) -> Bool {
        tick >= 0 && tick < count && bitamp_load_acquire_32(ready + tick) != 0
    }

    /// Where the playhead was last, in seconds.
    var playheadSeconds: Double { Double(bitamp_load_acquire_32(playhead)) * Self.tickSeconds }

    /// The tick a time in the song falls in.
    static func tick(at seconds: Double) -> Int {
        Int((seconds / tickSeconds).rounded(.down))
    }
}

/// Listens to a whole file with Basic Pitch on a background thread, a few seconds at a time
/// starting from wherever the playhead is, and arranges what it hears into a `ChipScore`.
/// MSNet follows the sung melody alongside, so the lead can carry the part people would hum.
/// Basic Pitch runs well over 100 times faster than real time and MSNet several times, so
/// it soon gets ahead of playback; it stays at most `aheadSeconds` ahead, waking now and
/// then to keep up, and stops at the end of the file.
final class NoteTranscription: @unchecked Sendable {
    /// A note, in seconds from the start of the file.
    struct Note: Equatable {
        var start: Double
        var end: Double
        var pitch: Int
        /// Basic Pitch's mean likelihood over the note, 0...1.
        var amplitude: Float
    }

    /// Windows (about 1.64 s each) transcribed at a time, and after starting somewhere new,
    /// so the first notes come quickly.
    static let segmentWindows = 6
    static let firstSegmentWindows = 2
    /// Extra window after each segment, so notes that run past its end get their length.
    static let lookaheadWindows = 1
    /// Notes this many frames or shorter (about 35 ms) are dropped.
    static let minimumFrames = 3
    /// How far ahead of the playhead the background work goes before it waits.
    static let aheadSeconds = 30.0

    let score: ChipScore
    /// Basic Pitch's thresholds, adjustable for tuning experiments.
    var onsetThreshold = BasicPitch.onsetThreshold
    var frameThreshold = BasicPitch.frameThreshold
    /// How full the arrangement is, adjustable for tuning experiments.
    var style = ChipArranger.Style()
    private let reader: BasicPitchReader
    private let model: () -> BasicPitch?
    /// MSNet on the file at 44.1 kHz, for the vocal line; nil when MSNet is unavailable.
    private let vocalTracker: VocalTracker?
    /// How many Basic Pitch windows cover the file.
    let windowCount: Int

    private let lock = NSLock()
    /// The window the playhead is in, where the next segment starts. Guarded by `lock`.
    private var wanted = 0
    private var cancelled = false
    private var allNotes: [Note] = []
    private var running = false
    /// Whether `start()` was ever called, so `prioritize` knows to restart the work.
    private var started = false

    // Worker state, touched only by whichever thread is transcribing.
    private var done: [Bool]
    /// Where the last segment ended, its notes that carry on past there, and the
    /// arrangement's state there, so the next segment can pick up seamlessly.
    private var lastEnd = -1
    private var carried: [Note] = []
    private lazy var arranger = ChipArranger(style: style)
    private lazy var vocalLine = makeVocalLine()

    /// Seconds of audio transcribed, and how long it took, for measuring speed.
    private(set) var secondsTranscribed = 0.0
    private(set) var secondsSpent = 0.0

    init(url: URL, score: ChipScore, model: @escaping () -> BasicPitch? = { BasicPitch.shared },
         vocalModel: () -> MSNet? = { MSNet.shared }) throws {
        reader = try BasicPitchReader(url: url)
        if let vocal = vocalModel() {
            let vocalReader = try BasicPitchReader(url: url, sampleRate: CFP.sampleRate)
            vocalTracker = VocalTracker(model: vocal, length: vocalReader.length) { start, count, out in
                try vocalReader.read(from: start, count: count, into: out)
            }
        } else {
            vocalTracker = nil
        }
        self.score = score
        self.model = model
        windowCount = max(1, (reader.length + BasicPitch.windowHop - 1) / BasicPitch.windowHop)
        done = Array(repeating: false, count: windowCount)
    }

    /// Every note found so far.
    var notes: [Note] {
        lock.lock()
        defer { lock.unlock() }
        return allNotes
    }

    /// Starts transcribing in the background, if it isn't already.
    func start() {
        lock.lock()
        let alreadyRunning = running
        running = true
        started = true
        lock.unlock()
        guard !alreadyRunning else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                while let segment = nextSegment(stoppingWhenDone: true) {
                    lock.lock()
                    let from = max(Double(wanted * BasicPitch.windowHop) / BasicPitch.sampleRate, score.playheadSeconds)
                    lock.unlock()
                    if BasicPitch.time(window: segment.lowerBound, frame: 0) - from > Self.aheadSeconds {
                        Thread.sleep(forTimeInterval: 0.25)
                        continue
                    }
                    try process(segment)
                }
            } catch {
                NSLog("Bitamp: transcription stopped: \(error)")
                score.markUnusable()
                lock.lock()
                running = false
                lock.unlock()
            }
        }
    }

    /// Stops the background work after the segment in progress.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Moves the transcription to the playhead, at `seconds` into the file.
    /// Starts the background work again if it had finished.
    func prioritize(_ seconds: Double) {
        lock.lock()
        wanted = min(windowCount - 1, max(0, Int(seconds * BasicPitch.sampleRate) / BasicPitch.windowHop))
        let restart = started && !running && !cancelled
        lock.unlock()
        if restart { start() }
    }

    /// Transcribes from `start` to `end` seconds on this thread, for tests and the harness.
    /// Not while `start()` is running.
    func transcribe(from start: Double, to end: Double) throws {
        prioritize(start)
        let last = min(windowCount - 1, Int(end * BasicPitch.sampleRate) / BasicPitch.windowHop)
        let first = min(windowCount - 1, max(0, Int(start * BasicPitch.sampleRate) / BasicPitch.windowHop))
        while !done[first...last].allSatisfy({ $0 }), let segment = nextSegment() {
            try process(segment)
        }
    }

    /// The next windows to transcribe, from the playhead's window on. When there are none
    /// and `stoppingWhenDone`, the background work is marked as stopped, under the same lock
    /// as `prioritize`, so a seek can't slip between the check and the stop.
    private func nextSegment(stoppingWhenDone: Bool = false) -> Range<Int>? {
        // Loading the model can take a while the first time, so not under the lock.
        let available = model() != nil
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, available else {
            if !cancelled { score.markUnusable() }
            if stoppingWhenDone { running = false }
            return nil
        }
        guard let first = (wanted..<windowCount).first(where: { !done[$0] }) else {
            if stoppingWhenDone { running = false }
            return nil
        }
        let size = first == lastEnd ? Self.segmentWindows : Self.firstSegmentWindows
        var end = first + 1
        while end < min(windowCount, first + size) && !done[end] { end += 1 }
        return first..<end
    }

    /// Runs Basic Pitch over `windows` (and a lookahead window), finds the notes that start
    /// there, and arranges every tick the windows cover.
    private func process(_ windows: Range<Int>) throws {
        guard let model = model() else { return }
        let began = Date()
        let continuing = windows.lowerBound == lastEnd
        if !continuing {
            carried = []
            arranger = ChipArranger(style: style)
            vocalLine = makeVocalLine()
        }

        // The audio: window w starts `edgeFrames` hops before sample w * windowHop.
        let total = windows.count + Self.lookaheadWindows
        let audioStart = windows.lowerBound * BasicPitch.windowHop - BasicPitch.edgeFrames * BasicPitch.fftHop
        let audioCount = (total - 1) * BasicPitch.windowHop + BasicPitch.windowSamples
        var audio = [Float](repeating: 0, count: audioCount)
        try audio.withUnsafeMutableBufferPointer { try reader.read(from: audioStart, count: audioCount, into: $0.baseAddress!) }

        let rows = total * BasicPitch.keptFrames
        var frames = [Float](repeating: 0, count: rows * BasicPitch.noteCount)
        var onsets = frames
        try audio.withUnsafeBufferPointer { audio in
            try frames.withUnsafeMutableBufferPointer { frames in
                try onsets.withUnsafeMutableBufferPointer { onsets in
                    for i in 0..<total {
                        let offset = i * BasicPitch.keptFrames * BasicPitch.noteCount
                        try model.predict(audio.baseAddress! + i * BasicPitch.windowHop,
                                          notes: frames.baseAddress! + offset, onsets: onsets.baseAddress! + offset)
                    }
                }
            }
        }

        // Frames count from window 0, so they line up across segments.
        let firstFrame = windows.lowerBound * BasicPitch.keptFrames
        func time(_ frame: Int) -> Double {
            BasicPitch.time(window: frame / BasicPitch.keptFrames, frame: frame % BasicPitch.keptFrames)
        }
        func frame(_ seconds: Double) -> Int {
            let window = Int(seconds * BasicPitch.sampleRate) / BasicPitch.windowHop
            let rest = seconds - BasicPitch.time(window: window, frame: 0)
            return window * BasicPitch.keptFrames + min(BasicPitch.keptFrames - 1, Int((rest / ChipScore.tickSeconds).rounded()))
        }
        let known = carried.map {
            BasicPitch.FrameNote(start: frame($0.start) - firstFrame, end: frame($0.end) - firstFrame, pitch: $0.pitch, amplitude: $0.amplitude)
        }
        let found = BasicPitch.decodeNotes(frames: frames, onsets: onsets, count: rows, known: known,
                                           minimumLength: Self.minimumFrames,
                                           onsetThreshold: onsetThreshold, frameThreshold: frameThreshold)
        let segmentRows = windows.count * BasicPitch.keptFrames
        let fresh = found.filter { $0.start < segmentRows }
            .map { Note(start: time($0.start + firstFrame), end: time($0.end + firstFrame), pitch: $0.pitch, amplitude: $0.amplitude) }
            .sorted { $0.start < $1.start }

        // Arrange every tick from this segment's start to the next's.
        let startTime = BasicPitch.time(window: windows.lowerBound, frame: 0)
        let endTime = BasicPitch.time(window: windows.upperBound, frame: 0)
        let firstTick = Int((startTime / ChipScore.tickSeconds).rounded(.up))
        let endTick = min(score.count, Int((endTime / ChipScore.tickSeconds).rounded(.up)))
        let sounding = carried + fresh
        if firstTick < endTick {
            let vocal = try vocalNotes(ticks: firstTick..<endTick)
            audio.withUnsafeBufferPointer { audio in
                for tick in firstTick..<endTick {
                    let center = tick * BasicPitch.fftHop - audioStart
                    let level = Self.loudnessLevel(audio, around: center)
                    var moment = arranger.arrange(sounding, tick: tick, level: level)
                    if let vocal { moment = arranger.addVocal(vocal[tick - firstTick], to: moment) }
                    score.write(moment, at: tick)
                }
            }
        }

        for window in windows { done[window] = true }
        lastEnd = windows.upperBound
        carried = sounding.filter { $0.end > endTime }
        lock.lock()
        allNotes += fresh
        lock.unlock()
        secondsTranscribed += endTime - startTime
        secondsSpent += Date().timeIntervalSince(began)
    }

    private func makeVocalLine() -> VocalLine {
        var line = VocalLine()
        line.holdRange = style.vocalHoldRange
        line.shortestNote = style.shortestVocalTicks
        return line
    }

    /// The vocal line's note at each tick of `ticks`, or nil without MSNet.
    private func vocalNotes(ticks: Range<Int>) throws -> [Int?]? {
        guard let vocalTracker else { return nil }
        let lookahead = ticks.lowerBound..<(ticks.upperBound + VocalLine.lookahead)
        let pitches = try vocalTracker.pitches(ticks: lookahead)
        return vocalLine.notes(pitches, count: ticks.count)
    }

    /// How loud the music is around sample `center` of `audio`, as a 4-bit volume:
    /// 0 at -50 dBFS or quieter, 15 at -10 dBFS and up.
    static func loudnessLevel(_ audio: UnsafeBufferPointer<Float>, around center: Int) -> Int {
        let start = max(0, center - 384), end = min(audio.count, center + 640)
        guard end > start else { return 0 }
        var sum: Float = 0
        for i in start..<end { sum += audio[i] * audio[i] }
        let decibels = 10 * log10(max(sum / Float(end - start), 1e-12)) + 3
        return decibels > -50 ? Int((15 * min(1, (decibels + 50) / 40)).rounded()) : 0
    }
}

/// Arranges the notes sounding at each moment for the chip, as someone covering a song for
/// an old console might: the melody on the lead, the lowest note on the bass, and what's
/// left of the chord as a fast arpeggio.
struct ChipArranger {
    /// What the arrangement plays besides the tune. The defaults are the sparse cover picked
    /// by ear (2026-10-07) over the fuller one, `full`, which sounded too busy.
    struct Style {
        /// Arpeggiate what's left of the chord.
        var chord = false
        /// While the vocal line sounds, keep the arranged lead, on the chord voice.
        var accompanyVocal = false
        /// Notes shorter than these never take the lead or the bass, in seconds.
        var shortestLead = 0.15
        var shortestBass = 0.1
        /// How far the voice may wander, in semitones, and how few ticks it may hold a note,
        /// before a new note starts.
        var vocalHoldRange = VocalLine.holdRange
        var shortestVocalTicks = VocalLine.shortestNote

        /// The arrangement before the vocal line: arpeggios, and a lead from 60 ms notes.
        static let full = Style(chord: true, accompanyVocal: true, shortestLead: ChipArranger.shortestLead, shortestBass: 0)
    }

    var style = Style()

    /// Notes below E3 can be bass.
    static let bassTop = 52
    /// How loud, against the loudest note sounding, a note must be to take the lead.
    static let leadShare: Float = 0.6
    /// Notes shorter than this never take the lead: in a band they're mostly riff chugs and
    /// picking noise, and on the lead they'd hide the tune.
    static let shortestLead = 0.06
    /// For this long after the lead's note ends, the lead waits for the tune to go on
    /// rather than dropping far down to whatever else is playing.
    static let leadGap = 0.15
    /// How far below the last lead note a new one may start without being long, in semitones.
    static let leadDrop = 7
    /// How long a note must be to take the lead after a bigger drop.
    static let longDrop = 0.15
    /// After a sustained melody note (at least `legatoNote` long) ends with nothing to follow
    /// it, the lead holds it for up to `legatoHold`, so a slow line like a chant, which the
    /// model hears only in fragments, plays as a line instead of scattered blips.
    static let legatoNote = 0.25
    static let legatoHold = 0.6
    /// How loud the chord and the bass are against the lead, so the tune stays in front.
    static let chordScale: Float = 0.5
    static let bassScale: Float = 0.8
    static let chordSize = 3
    /// A note with less than this left to play doesn't join the chord.
    static let blip = 0.04
    /// Semitones above a note where its strongest overtones are heard.
    static let overtones: Set<Int> = [12, 19, 24]

    /// While the vocal line sounds, the lead it displaces plays this loud on the chord voice.
    static let displacedLeadScale: Float = 0.7
    /// The vocal line's lead is at least this loud.
    static let vocalLevel: UInt8 = 8

    private var lead: NoteTranscription.Note?
    /// The last note the lead played, kept after it ends, to judge what may follow it.
    private var lastLead: NoteTranscription.Note?
    private var bass: NoteTranscription.Note?
    private var chord: [Int] = []
    private var vocal: Int?

    mutating func arrange(_ notes: [NoteTranscription.Note], tick: Int, level: Int) -> ChipMoment {
        let start = Double(tick) * ChipScore.tickSeconds, end = start + ChipScore.tickSeconds
        let all = notes.filter { $0.start < end && $0.end > start }
        // Leave out what's likely an overtone: a fainter note an octave, a twelfth or two
        // octaves above a note that started with it.
        let sounding = all.filter { note in
            !all.contains { other in
                Self.overtones.contains(note.pitch - other.pitch) && other.amplitude > note.amplitude * 1.3
                    && abs(other.start - note.start) < 0.03
            }
        }
        func starts(_ note: NoteTranscription.Note) -> Bool { note.start >= start && note.start < end }
        var moment = ChipMoment()
        guard level > 0, !sounding.isEmpty else {
            lead = nil
            lastLead = nil
            bass = nil
            chord = []
            return moment
        }

        // The bass keeps its note while it sounds, else takes the lowest low note.
        if let current = bass, sounding.contains(current), !sounding.contains(where: { starts($0) && $0.pitch < Self.bassTop }) {
            bass = current
        } else {
            bass = sounding.filter { $0.pitch < Self.bassTop && $0.end - $0.start >= style.shortestBass }.min { $0.pitch < $1.pitch }
        }

        // The lead follows the tune: the highest loud note long enough to be part of a
        // melody. A new note at or near the current one takes over as it starts (melodies
        // move with their onsets); otherwise the current note holds while it lasts. When it
        // ends, the lead waits briefly for the tune to go on rather than dropping far down
        // to the accompaniment, and a big drop needs a long note.
        let rest = sounding.filter { $0 != bass }
        let loudest = rest.map(\.amplitude).max() ?? 0
        let candidates = rest.filter {
            $0.amplitude >= loudest * Self.leadShare && $0.end - $0.start >= style.shortestLead
        }
        func fits(_ note: NoteTranscription.Note) -> Bool {
            guard let last = lastLead else { return true }
            let dropped = note.pitch < last.pitch - Self.leadDrop
            let waiting = start - last.end < Self.leadGap
            return !dropped || (!waiting && note.end - note.start >= Self.longDrop)
        }
        let fresh = candidates.filter { starts($0) && fits($0) && $0.pitch >= (lead?.pitch ?? 0) - 5 }
        if let new = fresh.max(by: { $0.pitch < $1.pitch }) {
            lead = new
        } else if let current = lead, rest.contains(current) {
            lead = current
        } else {
            lead = candidates.filter(fits).max { $0.pitch < $1.pitch }
        }
        if let lead { lastLead = lead }

        // The chord: the loudest of the rest, low to high, leaving out doubled notes and the
        // tail of a note the lead just left, which would only blip.
        var others = rest.filter {
            $0 != lead && $0.pitch != lead?.pitch && $0.pitch != bass?.pitch
                && ($0.end - start > Self.blip || chord.contains($0.pitch))
        }
        others.sort { $0.amplitude > $1.amplitude }
        var pitches: [Int] = []
        for note in others where style.chord && !pitches.contains(note.pitch) && pitches.count < Self.chordSize {
            pitches.append(note.pitch)
        }
        pitches.sort()

        func volume(_ note: NoteTranscription.Note?, scale: Float = 1) -> UInt8 {
            guard let note else { return 0 }
            let share = 0.6 + 0.4 * min(1, note.amplitude / 0.7)
            return UInt8(max(1, min(15, (Float(level) * share * scale).rounded())))
        }
        if let lead {
            moment.lead = UInt8(lead.pitch)
            moment.leadLevel = volume(lead)
            if starts(lead) { moment.onsets |= ChipMoment.leadOnset }
        } else if let last = lastLead, last.end - last.start >= Self.legatoNote,
                  start - last.end < Self.legatoHold {
            moment.lead = UInt8(last.pitch)
            moment.leadLevel = volume(last)
        }
        if let bass {
            moment.bass = UInt8(bass.pitch)
            moment.bassLevel = volume(bass, scale: Self.bassScale)
            if starts(bass) { moment.onsets |= ChipMoment.bassOnset }
        }
        if !pitches.isEmpty {
            let notes = rest.filter { pitches.contains($0.pitch) }
            moment.chord = (UInt8(pitches[0]), pitches.count > 1 ? UInt8(pitches[1]) : 0, pitches.count > 2 ? UInt8(pitches[2]) : 0)
            moment.chordLevel = volume(notes.max { $0.amplitude < $1.amplitude }, scale: Self.chordScale)
            if notes.contains(where: starts) || pitches != chord { moment.onsets |= ChipMoment.chordOnset }
        }
        chord = pitches
        return moment
    }

    /// Lays the vocal line (`note`, nil when no one is singing) over an arranged moment.
    /// While it sounds it takes the lead, and the lead `arrange` chose, if different, moves
    /// to the chord voice in place of the arpeggio, quieter; elsewhere the moment is as arranged.
    mutating func addVocal(_ note: Int?, to arranged: ChipMoment) -> ChipMoment {
        defer { vocal = note }
        guard let note else { return arranged }
        var moment = arranged
        let ownLead = moment.lead, ownOnset = moment.onsets & ChipMoment.leadOnset != 0
        moment.onsets &= ~ChipMoment.leadOnset
        if !style.accompanyVocal {
            moment.chord = (0, 0, 0)
            moment.chordLevel = 0
            moment.onsets &= ~ChipMoment.chordOnset
        } else if ownLead != 0 && ownLead != UInt8(note) {
            moment.chord = (ownLead, 0, 0)
            moment.chordLevel = UInt8(max(1, (Float(moment.leadLevel) * Self.displacedLeadScale).rounded()))
            if ownOnset { moment.onsets |= ChipMoment.chordOnset }
        }
        moment.lead = UInt8(note)
        moment.leadLevel = max(moment.leadLevel, moment.bassLevel, moment.chordLevel, Self.vocalLevel)
        if vocal != note { moment.onsets |= ChipMoment.leadOnset }
        return moment
    }
}
