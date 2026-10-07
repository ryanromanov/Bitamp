import AVFoundation
import BitampAtomics

/// How the retro sound setting changes the music.
enum RetroSound: String, CaseIterable {
    /// The music as it is.
    case off
    /// The music as 8-bit samples, by `BitCrusher`.
    case crush
    /// An 8-bit cover of the music, by `NoteTranscription` (or, without it,
    /// `ChipTranscriber`) and `ChipSynth`. Experimental.
    case chiptune
}

/// How much of the original song plays under the chiptune cover. The cover misses what the
/// transcription can't hear, like a choir; a little of the song keeps those parts there.
enum ChipBlend: String, CaseIterable {
    case none, low, medium

    var level: Float {
        switch self {
        case .none: return 0
        case .low: return 0.2
        case .medium: return 0.4
        }
    }
}

/// The retro sound setting's place in the audio chain: an in-process effect after the
/// equalizer that crushes the music or replaces it with a chip cover. Switching fades over
/// a few milliseconds, so it doesn't click.
final class RetroAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: fourCC("rtro"),
        componentManufacturer: fourCC("Btmp"), componentFlags: 0, componentFlagsMask: 0)

    /// Registers the unit with this process once; call before creating an `AVAudioUnitEffect`.
    static let register: Void = {
        AUAudioUnit.registerSubclass(RetroAudioUnit.self, as: componentDescription, name: "Bitamp: Retro Sound", version: 1)
    }()

    /// The engine's node for a new retro sound unit.
    static func makeNode() -> AVAudioUnitEffect {
        _ = register
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// Everything the render thread touches, kept apart from the Objective-C object.
    final class Kernel: @unchecked Sendable {
        let transcriber = ChipTranscriber()
        let synth = ChipSynth()
        let crusher = BitCrusher()
        /// Set from the main thread, read on the render thread; a stale read only delays the fade.
        var mode = RetroSound.off
        /// How much of the music stays under the chip, 0...1. Set from the main thread.
        var blend: Float = 0
        /// How much of the crushed music and of the chip are in the output, fading toward `mode`.
        var crushMix: Float = 0
        var chipMix: Float = 0
        var fadeStep: Float = 0.005
        var sinceHop = 0

        /// The playing file's chip arrangement, worked out ahead by `NoteTranscription`.
        /// Set only while the engine is stopped. Without one, or while it's unusable, the
        /// chip plays what `ChipTranscriber` hears live; with one, `ChipTranscriber` only
        /// supplies the drums, and the chip is quiet wherever the score isn't ready yet.
        var score: ChipScore?
        /// Score ticks per file frame, and the tick the synth last took.
        private var ticksPerFrame = 1.0
        private var currentTick = Int.min
        /// Where the render clock is in the file: the file frame is the render timestamp's
        /// sample time plus this, or `noClock` when playback hasn't been timed yet.
        private let clockOffset: UnsafeMutablePointer<Int64> = {
            let pointer = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
            pointer.initialize(to: noClock)
            return pointer
        }()
        static let noClock = Int64.min
        /// The latest render's sample time, for tests.
        private(set) var lastSampleTime: Double?
        var mono: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
        var chip: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
        var capacity = 1

        func prepare(sampleRate: Double, maxFrames: Int) {
            transcriber.prepare(sampleRate: sampleRate)
            synth.prepare(sampleRate: sampleRate)
            crusher.prepare(sampleRate: sampleRate)
            sinceHop = 0
            currentTick = Int.min
            ticksPerFrame = 1 / (ChipScore.tickSeconds * sampleRate)
            fadeStep = Float(1 / (0.02 * sampleRate))
            if maxFrames > capacity {
                mono.deallocate()
                chip.deallocate()
                mono = .allocate(capacity: maxFrames)
                chip = .allocate(capacity: maxFrames)
                capacity = maxFrames
            }
        }

        deinit {
            mono.deallocate()
            chip.deallocate()
            clockOffset.deallocate()
        }

        /// Tells the render thread which file frame plays at render sample time 0, or that
        /// it doesn't know (nil). From any thread.
        func setClock(offset: Int64?) {
            bitamp_store_release_64(clockOffset, offset ?? Self.noClock)
        }

        /// Mixes `channels` down for analysis, renders the chip, and writes the music, the
        /// crushed music and the chip, blended by the fades, back over the channels.
        /// `sampleTime` is the render timestamp's, if it has one.
        func process(_ channels: UnsafeMutableAudioBufferListPointer, frames: Int, sampleTime: Double? = nil) {
            let channelCount = channels.count
            guard frames <= capacity, channelCount > 0 else { return }
            mono.update(repeating: 0, count: frames)
            for channel in channels {
                guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += data[i] }
            }
            let gain = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= gain }

            // The score, and the file frame this render starts at, when both are known.
            let score = self.score.flatMap { $0.isUsable ? $0 : nil }
            let offset = bitamp_load_acquire_64(clockOffset)
            let startFrame: Int64? = offset == Self.noClock ? nil : sampleTime.map { Int64($0) + offset }
            lastSampleTime = sampleTime

            // Render in pieces that end on hop and tick boundaries, so new notes start on time.
            var done = 0
            while done < frames {
                var piece = min(frames - done, ChipTranscriber.hop - sinceHop)
                if let score {
                    if let startFrame {
                        let frame = startFrame + Int64(done)
                        let tick = Int((Double(frame) * ticksPerFrame).rounded(.down))
                        if tick != currentTick {
                            currentTick = tick
                            synth.play(score.moment(at: tick) ?? ChipMoment())
                        }
                        let next = Int64((Double(tick + 1) / ticksPerFrame).rounded(.up))
                        piece = min(piece, max(1, Int(next - frame)))
                    } else if currentTick != Int.min {
                        currentTick = Int.min
                        synth.play(ChipMoment())
                    }
                }
                transcriber.push(mono + done, count: piece)
                synth.render(into: chip + done, count: piece)
                sinceHop += piece
                done += piece
                if sinceHop == ChipTranscriber.hop {
                    sinceHop = 0
                    transcriber.analyze()
                    if score == nil {
                        synth.play(transcriber.frame)
                    } else if let drum = transcriber.frame.drum {
                        synth.hit(drum)
                    }
                }
            }

            let crushTarget: Float = mode == .crush ? 1 : 0
            let chipTarget: Float = mode == .chiptune ? 1 : 0
            if crushMix == 0 && chipMix == 0 && crushTarget == 0 && chipTarget == 0 { return }
            for i in 0..<frames {
                crushMix = fade(crushMix, toward: crushTarget)
                chipMix = fade(chipMix, toward: chipTarget)
                for (c, channel) in channels.enumerated() {
                    guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var sample = data[i]
                    if crushMix > 0 {
                        sample += (crusher.process(sample, channel: c) - sample) * crushMix
                    }
                    data[i] = sample * (1 - chipMix * (1 - blend)) + chip[i] * chipMix
                }
            }
        }

        private func fade(_ value: Float, toward target: Float) -> Float {
            value < target ? min(target, value + fadeStep) : max(target, value - fadeStep)
        }
    }

    let kernel = Kernel()
    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBus.maximumChannelCount = 8
        outputBus.maximumChannelCount = 8
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.prepare(sampleRate: outputBus.format.sampleRate, maxFrames: Int(maximumFramesToRender))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            // Pull the music straight into the output buffers, then work on it in place.
            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            let time = timestamp.pointee
            let sampleTime = time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : nil
            kernel.process(UnsafeMutableAudioBufferListPointer(outputData), frames: Int(frameCount), sampleTime: sampleTime)
            return noErr
        }
    }
}

private func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
