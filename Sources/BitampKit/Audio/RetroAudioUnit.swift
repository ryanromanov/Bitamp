import AVFoundation

/// How the retro sound setting changes the music.
enum RetroSound: String, CaseIterable {
    /// The music as it is.
    case off
    /// The music as 8-bit samples, by `BitCrusher`.
    case crush
    /// An 8-bit cover of the music, by `ChipTranscriber` and `ChipSynth`. Experimental.
    case chiptune
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
        /// How much of the crushed music and of the chip are in the output, fading toward `mode`.
        var crushMix: Float = 0
        var chipMix: Float = 0
        var fadeStep: Float = 0.005
        var sinceHop = 0
        var chip: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
        var capacity = 1

        func prepare(sampleRate: Double, maxFrames: Int) {
            transcriber.prepare(sampleRate: sampleRate)
            synth.prepare(sampleRate: sampleRate)
            crusher.prepare(sampleRate: sampleRate)
            sinceHop = 0
            fadeStep = Float(1 / (0.02 * sampleRate))
            if maxFrames > capacity {
                chip.deallocate()
                chip = .allocate(capacity: maxFrames)
                capacity = maxFrames
            }
        }

        deinit {
            chip.deallocate()
        }

        /// Hands the first two channels to the transcriber (one channel counts as both), renders
        /// the chip, and writes the music, the crushed music and the chip, blended by the
        /// fades, back over the channels.
        func process(_ channels: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let channelCount = channels.count
            guard frames <= capacity, channelCount > 0,
                  let left = channels[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = channels[min(1, channelCount - 1)].mData?.assumingMemoryBound(to: Float.self)
            else { return }

            // Render in pieces that end on hop boundaries, so new notes start on time.
            var done = 0
            while done < frames {
                let piece = min(frames - done, ChipTranscriber.hop - sinceHop)
                transcriber.push(left: left + done, right: right + done, count: piece)
                synth.render(into: chip + done, count: piece)
                sinceHop += piece
                done += piece
                if sinceHop == ChipTranscriber.hop {
                    sinceHop = 0
                    transcriber.analyze()
                    synth.play(transcriber.frame)
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
                    data[i] = sample * (1 - chipMix) + chip[i] * chipMix
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
            kernel.process(UnsafeMutableAudioBufferListPointer(outputData), frames: Int(frameCount))
            return noErr
        }
    }
}

private func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
