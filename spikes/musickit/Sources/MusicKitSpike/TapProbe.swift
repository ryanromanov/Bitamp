import AudioToolbox
import CoreAudio
import Foundation

/// Answers the visualizer spike's question: while MusicKit plays a song, can a Core Audio
/// process tap hear it, and from which process? Needs macOS 14.2 and the user's OK to
/// record other apps' audio (NSAudioCaptureUsageDescription).
@available(macOS 14.2, *)
enum TapProbe {
    struct AudioProcess {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    struct Result: CustomStringConvertible {
        var format = "?"
        var frames = 0
        var rms: Float = 0
        var peak: Float = 0
        var error: String?

        var description: String {
            if let error { return "error: \(error)" }
            let decibels = 20 * log10(max(rms, 1e-9))
            return "\(format), \(frames) frames, rms \(String(format: "%.4f", rms)) (\(String(format: "%.0f", decibels)) dB), peak \(String(format: "%.3f", peak))"
        }
    }

    // MARK: - Processes

    static func processes() -> [AudioProcess] {
        let objects: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.map { object in
            AudioProcess(
                object: object,
                pid: scalar(object, kAudioProcessPropertyPID, pid_t(-1)),
                bundleID: string(object, kAudioProcessPropertyBundleID) ?? "?",
                isRunningOutput: scalar(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0)
        }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    // MARK: - Measuring

    /// Taps what `description` covers for `seconds` and measures the level.
    static func measure(_ description: CATapDescription, seconds: Double) async -> Result {
        var result = Result()
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { result.error = "AudioHardwareCreateProcessTap \(status)"; return result }
        defer { AudioHardwareDestroyProcessTap(tap) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        result.format = "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit, \(interleaved ? "interleaved" : "planar")"

        guard let output = string(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, isDevice: true)
        else { result.error = "no default output device"; return result }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bitamp Tap Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { result.error = "AudioHardwareCreateAggregateDevice \(status)"; return result }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        let meter = Meter()
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, DispatchQueue(label: "tap-probe")) { _, input, _, _, _ in
            meter.add(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }
        guard status == noErr, let proc else { result.error = "AudioDeviceCreateIOProcIDWithBlock \(status)"; return result }
        defer { AudioDeviceDestroyIOProcID(aggregate, proc) }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { result.error = "AudioDeviceStart \(status)"; return result }
        try? await Task.sleep(for: .seconds(seconds))
        AudioDeviceStop(aggregate, proc)

        (result.frames, result.rms, result.peak) = meter.reading(channels: Int(format.mChannelsPerFrame))
        return result
    }

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var samples = 0
        private var squares: Double = 0
        private var peak: Float = 0

        func add(_ buffers: UnsafeMutableAudioBufferListPointer) {
            var count = 0, sum: Double = 0, loudest: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    sum += Double(floats[i] * floats[i])
                    loudest = max(loudest, abs(floats[i]))
                }
                count += Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            }
            lock.lock()
            samples += count
            squares += sum
            peak = max(peak, loudest)
            lock.unlock()
        }

        func reading(channels: Int) -> (frames: Int, rms: Float, peak: Float) {
            lock.lock()
            defer { lock.unlock() }
            return (samples / max(channels, 1), samples == 0 ? 0 : Float((squares / Double(samples)).squareRoot()), peak)
        }
    }

    // MARK: - Properties

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// A CFString property, or with `isDevice`, the UID of the device the property names.
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, isDevice: Bool = false) -> String? {
        if isDevice {
            let device = scalar(object, selector, AudioObjectID(kAudioObjectUnknown))
            guard device != kAudioObjectUnknown else { return nil }
            return string(device, kAudioDevicePropertyDeviceUID)
        }
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
