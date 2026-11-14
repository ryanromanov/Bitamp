import Accelerate
import AVFoundation

/// Turns tapped audio into 19 spectrum bars and a 76-point waveform.
///
/// `process(_:)` runs on the audio tap's thread; everything else is main-thread only.
/// The two sides share `target` and `wave` under `lock`.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let barCount = 19
    static let waveformCount = 76
    static let fftSize = 2048
    static let minFrequency = 40.0
    static let maxFrequency = 16_000.0

    /// Data older than this counts as silence, so bars fall when playback stops.
    static let staleAfter: TimeInterval = 0.25

    // Shared, guarded by `lock`.
    private let lock = NSLock()
    private var target = [Float](repeating: 0, count: barCount)
    private var wave = [Float](repeating: 0, count: waveformCount)
    private var updatedAt: TimeInterval = 0
    private var bands: [Range<Int>]
    /// Sudden rises in the sound since the visualizer last asked, and the log spectrum they're
    /// measured against.
    private var onsets: [Onset] = []
    private var previousLogSpectrum = [Float](repeating: 0, count: fftSize / 2)

    // Tap thread only.
    private var history = [Float](repeating: 0, count: fftSize)
    private let window: [Float]
    private let log2n = vDSP_Length(log2(Double(fftSize)))
    private let fftSetup: FFTSetup

    // Main thread only.
    /// How far bars and peaks drop per display frame, as a fraction of full height.
    var barFall = Falloff.normal.barRate
    var peakFall = Falloff.normal.peakRate
    var peakHoldFrames = Falloff.normal.peakHoldFrames
    private(set) var bars = [Float](repeating: 0, count: barCount)
    private(set) var peaks = [Float](repeating: 0, count: barCount)
    /// The latest waveform, scaled by `scopeGain` to fill the display; clamped to -1...1.
    private(set) var waveform = [Float](repeating: 0, count: waveformCount)
    private var peakHold = [Int](repeating: 0, count: barCount)
    /// Recent waveform peak: jumps up with louder audio, eases back down.
    private var scopeLevel: Float = 0

    /// Music rarely peaks above ±0.3, which is only a couple of pixels on a 16-pixel
    /// scope, so the oscilloscope scales recent peaks up to about 90% of full height.
    static let scopeTarget: Float = 0.9
    static let scopeMaxGain: Float = 8
    /// Per frame; at 30 fps the level halves in about a second.
    static let scopeRelease: Float = 0.977

    var scopeGain: Float {
        min(Self.scopeTarget / max(scopeLevel, 1e-6), Self.scopeMaxGain)
    }

    init() {
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
        self.window = window
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        bands = Self.bandBins(sampleRate: 44_100)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    var sampleRate: Double = 44_100 {
        didSet {
            let bands = Self.bandBins(sampleRate: sampleRate)
            lock.lock()
            self.bands = bands
            lock.unlock()
        }
    }

    /// FFT bin ranges for each bar, log-spaced between `minFrequency` and `maxFrequency`.
    /// Every range is non-empty and they follow each other without gaps.
    static func bandBins(
        barCount: Int = barCount, fftSize: Int = fftSize, sampleRate: Double,
        minFrequency: Double = minFrequency, maxFrequency: Double = maxFrequency
    ) -> [Range<Int>] {
        let binWidth = sampleRate / Double(fftSize)
        let half = fftSize / 2
        let top = min(maxFrequency, sampleRate / 2)
        var low = max(1, Int(minFrequency / binWidth))
        var ranges: [Range<Int>] = []
        for i in 0..<barCount {
            let edge = minFrequency * pow(top / minFrequency, Double(i + 1) / Double(barCount))
            let high = min(max(Int((edge / binWidth).rounded()), low + 1), half)
            if low >= high { low = high - 1 }
            ranges.append(low..<high)
            low = high
        }
        return ranges
    }

    /// Maps a squared FFT magnitude from `vDSP_fft_zrip` with a Hann window to 0...1.
    /// A full-scale sine reads 0 dB; the bars span -60 to -6 dB.
    static func level(power: Float, fftSize: Int = fftSize, tilt: Float = 0) -> Float {
        let amplitude = power.squareRoot() * 2 / Float(fftSize)
        let decibels = 20 * log10(max(amplitude, 1e-9)) + tilt
        return min(max((decibels + 60) / 54, 0), 1)
    }

    /// Called from the audio tap. `time` says when the sound was heard, on the system's uptime
    /// clock, for the onsets; now, if left out.
    func process(_ buffer: AVAudioPCMBuffer, at time: TimeInterval? = nil) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        let n = Self.fftSize
        let take = min(frames, n)
        var mono = [Float](repeating: 0, count: take)
        for channel in 0..<channelCount {
            let samples = channels[channel] + (frames - take)
            for i in 0..<take { mono[i] += samples[i] }
        }
        let gain = 1 / Float(channelCount)
        for i in 0..<take { mono[i] *= gain }
        if take == n {
            history = mono
        } else {
            history.removeFirst(take)
            history.append(contentsOf: mono)
        }

        // The oscilloscope shows the most recent 512 samples.
        let span = 512
        let newWave = (0..<Self.waveformCount).map { history[n - span + $0 * span / Self.waveformCount] }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0  // Bin 0 packs DC and Nyquist together.

        // How much the sound just changed: the rise in log magnitude (spectral flux), counted
        // twice over: across the low end (40-220 Hz, where a kick drum or a bass note begins),
        // weighted by 3, and across everything from 50 Hz to 6 kHz, weighted by 1. A drum puts a
        // lot into a few low bins; a piano puts a little into many bins, so the low end
        // is what tells them apart. The visualizer's beat tracker works out which of these onsets
        // is the beat.
        let binWidth = sampleRate / Double(n)
        let lowest = max(1, Int(40 / binWidth)), bassTop = max(lowest + 1, Int(220 / binWidth))
        let high = min(n / 2 - 1, Int(6000 / binWidth))
        var allRise: Float = 0, bassRise: Float = 0
        if high > bassTop {
            for k in lowest..<high {
                let magnitude = power[k].squareRoot() * 2 / Float(n)
                let logMagnitude = log(1 + 300 * magnitude)
                let rise = max(0, logMagnitude - previousLogSpectrum[k])
                previousLogSpectrum[k] = logMagnitude
                if k < bassTop { bassRise += rise }
                if k >= max(1, Int(50 / binWidth)) { allRise += rise }
            }
        }
        let flux = 3 * bassRise / Float(max(1, bassTop - lowest)) + allRise / Float(max(1, high - max(1, Int(50 / binWidth))))
        let onsetTime = time ?? ProcessInfo.processInfo.systemUptime

        lock.lock()
        let bands = self.bands
        lock.unlock()

        var levels = [Float](repeating: 0, count: Self.barCount)
        for (i, band) in bands.enumerated() {
            let loudest = band.map { power[$0] }.max() ?? 0
            // Music falls off toward the treble; tilt the higher bars up to compensate.
            levels[i] = Self.level(power: loudest, tilt: Float(i) * 0.8)
        }

        lock.lock()
        target = levels
        wave = newWave
        onsets.append(Onset(time: onsetTime, strength: flux))
        if onsets.count > 400 { onsets.removeFirst(onsets.count - 400) }
        updatedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// The sudden rises in the sound since the last call, oldest first.
    func drainOnsets() -> [Onset] {
        lock.lock()
        defer { lock.unlock() }
        let drained = onsets
        onsets.removeAll(keepingCapacity: true)
        return drained
    }

    /// Moves the displayed bars and peaks one frame toward the latest data.
    func advance() {
        lock.lock()
        let fresh = ProcessInfo.processInfo.systemUptime - updatedAt < Self.staleAfter
        let target = fresh ? self.target : [Float](repeating: 0, count: Self.barCount)
        let wave = fresh ? self.wave : [Float](repeating: 0, count: Self.waveformCount)
        lock.unlock()

        let peak = wave.map(abs).max() ?? 0
        scopeLevel = max(peak, scopeLevel * Self.scopeRelease)
        let gain = scopeGain
        waveform = wave.map { min(max($0 * gain, -1), 1) }

        for i in 0..<Self.barCount {
            bars[i] = max(target[i], bars[i] - barFall)
            if bars[i] >= peaks[i] {
                peaks[i] = bars[i]
                peakHold[i] = peakHoldFrames
            } else if peakHold[i] > 0 {
                peakHold[i] -= 1
            } else {
                peaks[i] = max(0, peaks[i] - peakFall)
            }
        }
    }
}
