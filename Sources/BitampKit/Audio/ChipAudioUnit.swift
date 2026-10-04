import AVFoundation

/// The chiptune mode's place in the audio chain: an in-process effect that listens to the
/// music and, when on, replaces it with `ChipSynth` playing what `ChipTranscriber` hears.
/// Switching fades between the two over a few milliseconds, so it doesn't click.
final class ChipAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: fourCC("chip"),
        componentManufacturer: fourCC("Btmp"), componentFlags: 0, componentFlagsMask: 0)

    /// Registers the unit with this process once; call before creating an `AVAudioUnitEffect`.
    static let register: Void = {
        AUAudioUnit.registerSubclass(ChipAudioUnit.self, as: componentDescription, name: "Bitamp: Chiptune", version: 1)
    }()

    /// The engine's node for a new chiptune unit.
    static func makeNode() -> AVAudioUnitEffect {
        _ = register
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// Everything the render thread touches, kept apart from the Objective-C object.
    final class Kernel: @unchecked Sendable {
        let transcriber = ChipTranscriber()
        let synth = ChipSynth()
        /// Set from the main thread, read on the render thread; a stale read only delays the fade.
        var enabled = false
        var mix: Float = 0
        var fadeStep: Float = 0.005
        var sinceHop = 0
        var mono: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
        var chip: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
        var capacity = 1

        func prepare(sampleRate: Double, maxFrames: Int) {
            transcriber.prepare(sampleRate: sampleRate)
            synth.prepare(sampleRate: sampleRate)
            sinceHop = 0
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
        }

        /// Mixes `channels` down for analysis, renders the chip, and writes music and chip
        /// blended by `mix` back over the channels.
        func process(_ channels: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let channelCount = channels.count
            guard frames <= capacity, channelCount > 0 else { return }
            mono.update(repeating: 0, count: frames)
            for channel in channels {
                guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += data[i] }
            }
            let gain = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= gain }

            // Render in pieces that end on hop boundaries, so new notes start on time.
            var done = 0
            while done < frames {
                let piece = min(frames - done, ChipTranscriber.hop - sinceHop)
                transcriber.push(mono + done, count: piece)
                synth.render(into: chip + done, count: piece)
                sinceHop += piece
                done += piece
                if sinceHop == ChipTranscriber.hop {
                    sinceHop = 0
                    transcriber.analyze()
                    synth.play(transcriber.frame)
                }
            }

            let target: Float = enabled ? 1 : 0
            if mix == 0 && target == 0 { return }
            for i in 0..<frames {
                mix = mix < target ? min(target, mix + fadeStep) : max(target, mix - fadeStep)
                for channel in channels {
                    guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data[i] = data[i] * (1 - mix) + chip[i] * mix
                }
            }
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
