import AVFoundation
import CoreAudio

/// Lets the visualizer show a Pak that plays its own audio, by listening to the process
/// that plays it with a Core Audio process tap (macOS 14.2+) and feeding the analyzer.
///
/// MusicKit plays Apple Music in a helper, `com.apple.MediaPlayer.RemotePlayerService`,
/// not in Bitamp, so that's the process tapped. The first tap asks the user's permission
/// to record other apps' audio (NSAudioCaptureUsageDescription); if they say no, the tap
/// hears silence and the visualizer keeps showing the Pak's badge.
@MainActor
final class PakAudioListener {
    static let playerBundleID = "com.apple.MediaPlayer.RemotePlayerService"
    /// How often to look for the player's process again while tapping, in case it restarts.
    static let rescanInterval: TimeInterval = 1
    /// A running tap that hears nothing for this long stops counting as working.
    static let giveUpAfter: TimeInterval = 5

    private let analyzer: SpectrumAnalyzer
    private var tap: AnyObject?
    private var tapped: [AudioObjectID] = []
    private var scannedAt: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    /// When the tap last heard something other than silence, shared with the tap's queue.
    private let heard = HeardClock()

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    /// True while the tap is running and has heard audio in the last moment.
    var isHearing: Bool {
        tap != nil && ProcessInfo.processInfo.systemUptime - heard.time < SpectrumAnalyzer.staleAfter
    }

    /// Whether listening works: the tap has heard the player, and hasn't since failed or
    /// gone quiet for long. Kept while paused, so the visualizer stays rather than
    /// switching back to the Pak's badge.
    private(set) var works = false

    /// Starts or stops listening. Called every frame, so it only looks for the player's
    /// process once every `rescanInterval`.
    func update(listening: Bool) {
        guard #available(macOS 14.2, *) else { return }
        guard listening else { return stop() }
        let now = ProcessInfo.processInfo.systemUptime
        if isHearing {
            works = true
        } else if tap != nil, now - max(startedAt, heard.time) > Self.giveUpAfter {
            works = false
        }
        guard tap == nil || now - scannedAt >= Self.rescanInterval else { return }
        scannedAt = now
        let players = AudioProcesses.objects(bundleID: Self.playerBundleID)
        guard players != tapped else { return }
        stop()
        guard !players.isEmpty else {
            works = false
            return
        }
        do {
            let analyzer = self.analyzer, heard = self.heard
            let tap = try ProcessTap(processes: players) { buffer, loud in
                if loud { heard.mark() }
                analyzer.process(buffer)
            }
            analyzer.sampleRate = tap.sampleRate
            self.tap = tap
            tapped = players
            startedAt = now
        } catch {
            NSLog("Bitamp: couldn't listen to \(Self.playerBundleID): \(error)")
            tapped = players  // Don't retry until the processes change.
            works = false
        }
    }

    private func stop() {
        tap = nil
        tapped = []
    }
}

/// When a tap last heard sound, written on the tap's queue and read on the main thread.
private final class HeardClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0

    var time: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func mark() {
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
}

/// Core Audio's view of the processes playing or recording audio.
enum AudioProcesses {
    static func objects(bundleID: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return CoreAudioProperty.array(system, kAudioHardwarePropertyProcessObjectList)
            .filter { CoreAudioProperty.string($0, kAudioProcessPropertyBundleID) == bundleID }
            .sorted()
    }
}

/// A process tap on some processes' mixed output, delivered as planar float buffers on a
/// queue of its own. Stops and tears everything down when released.
@available(macOS 14.2, *)
final class ProcessTap {
    enum Failure: Error {
        case coreAudio(String, OSStatus)
        case noOutputDevice
        case unsupportedFormat
    }

    let sampleRate: Double
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?

    /// `onAudio` gets each buffer, and whether any of it was above silence.
    init(processes: [AudioObjectID], onAudio: @escaping @Sendable (AVAudioPCMBuffer, Bool) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tap))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = CoreAudioProperty.address(kAudioTapPropertyFormat)
        do {
            try Self.check("kAudioTapPropertyFormat", AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0
            else { throw Failure.unsupportedFormat }
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        sampleRate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        do {
            try start(tapUID: description.uuid.uuidString) { buffers in
                guard let buffer = Self.planarBuffer(buffers, channels: channels, interleaved: interleaved, sampleRate: format.mSampleRate)
                else { return }
                onAudio(buffer, Self.isAudible(buffer))
            }
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
    }

    private func start(tapUID: String, _ handle: @escaping (UnsafeMutableAudioBufferListPointer) -> Void) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let device = CoreAudioProperty.scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(kAudioObjectUnknown))
        guard let output = CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID) else { throw Failure.noOutputDevice }
        // A private device made of the output and the tap; the tap's audio arrives as its input.
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bitamp Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        try Self.check("AudioHardwareCreateAggregateDevice", AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate))
        // With a queue, the block runs there rather than on the real-time I/O thread.
        try Self.check("AudioDeviceCreateIOProcIDWithBlock", AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregate, DispatchQueue(label: "Bitamp visualizer tap")
        ) { _, input, _, _, _ in
            handle(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        })
        try Self.check("AudioDeviceStart", AudioDeviceStart(aggregate, proc))
    }

    private func teardown() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(call, status) }
    }

    /// The tap's audio as the analyzer takes it: one float array per channel. The tap gives
    /// interleaved stereo, normally; planar input is copied as is.
    static func planarBuffer(
        _ buffers: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool, sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        guard let first = buffers.first, let data = first.mData else { return nil }
        let samplesInFirst = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = interleaved ? samplesInFirst / channels : samplesInFirst
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if interleaved {
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                for frame in 0..<frames { out[channel][frame] = samples[frame * channels + channel] }
            }
        } else {
            for (channel, planar) in buffers.prefix(channels).enumerated() {
                guard let samples = planar.mData?.assumingMemoryBound(to: Float.self) else { continue }
                out[channel].update(from: samples, count: min(frames, Int(planar.mDataByteSize) / MemoryLayout<Float>.size))
            }
        }
        return buffer
    }

    /// Whether any sample is louder than about -90 dB.
    static func isAudible(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where abs(channels[channel][frame]) > 3e-5 { return true }
        }
        return false
    }
}

/// Reading Core Audio object properties.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
