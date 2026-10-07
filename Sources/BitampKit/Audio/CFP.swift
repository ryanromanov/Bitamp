import Accelerate
import Foundation

/// MSNet's input: the combined frequency and periodicity (CFP) features of Su's `cfp.py`
/// (in github.com/bill317996/Melody-extraction-with-melodic-segnet, MIT), with MSNet vocal's
/// settings. It is ported step for step, odd corners included, so the model sees what it was
/// trained on: for every 256 samples of 44.1 kHz mono, three maps over 320 log-spaced bins
/// from 31 Hz at 60 per octave. They are the spectrum, the generalized cepstrum of the
/// spectrum (which favors a note's fundamental) and the cepstrum (which favors its period).
///
/// Not for the render thread, and not thread-safe: each instance has its own work buffers.
final class CFP {
    static let sampleRate = 44_100.0
    static let hop = 256
    /// Points per transform: a 2 Hz frequency resolution.
    static let fftLength = 22_050
    static let windowLength = 2_049
    static let binCount = 320
    /// The centre frequencies, 31 Hz up to just under 1,250 Hz. MSNet's bin k (k ≥ 1) is
    /// `centralFrequencies[k]`; that's `cfp.py`'s mapping, one bin off its own rows.
    static let centralFrequencies: [Double] = {
        var frequencies: [Double] = []
        for i in 0..<360 {
            let frequency = 31.0 * pow(2, Double(i) / 60)
            guard frequency < 1_250 else { break }
            frequencies.append(frequency)
        }
        return frequencies
    }()
    /// Spectrum bins up to 1,250 Hz, and quefrency bins down to 31 Hz.
    static let spectrumBins = 626
    static let quefrencyBins = 1_424
    /// Low quefrencies and low frequencies cleared before each layer's nonlinearity.
    static let cepstrumCutoff = 35
    static let spectrumCutoff = 16

    /// One output row's nonzero span of a mapping onto the log-frequency bins.
    struct Band {
        var start: Int
        var weights: [Double]
    }

    /// `Freq2LogFreqMapping`: triangles between neighboring centre frequencies over the
    /// spectrum bins, whose frequencies are `linspace(0, fs / 2, 11025)`, not quite 2 Hz apart.
    static let spectrumBands: [Band] = {
        let cf = centralFrequencies
        let step = 0.5 / Double(fftLength / 2 - 1)
        func f(_ j: Int) -> Double { sampleRate * (Double(j) * step) }
        return triangles(over: f) { i in
            let l = Int((cf[i - 1] / 2).rounded(.toNearestOrEven))
            let r = Int((cf[i + 1] / 2).rounded(.toNearestOrEven)) + 1
            return l >= r - 1 ? .single(l) : .span(l..<r)
        }
    }()

    /// `Quef2LogFreqMapping`: the same triangles over the quefrency bins, at 1 / quefrency.
    static let quefrencyBands: [Band] = {
        let cf = centralFrequencies
        func f(_ j: Int) -> Double { 1 / (Double(j) / sampleRate) }
        return triangles(over: f) { i in
            .span(Int((sampleRate / cf[i + 1]).rounded(.toNearestOrEven))
                  ..< Int((sampleRate / cf[i - 1]).rounded(.toNearestOrEven)) + 1)
        }
    }()

    private enum Span {
        case single(Int)
        case span(Range<Int>)
    }

    /// Rows 1...319 of 320 get a triangle peaking at their centre frequency; row 0 stays
    /// empty, as in `cfp.py`.
    private static func triangles(over f: (Int) -> Double, span: (Int) -> Span) -> [Band] {
        let cf = centralFrequencies
        var bands = [Band(start: 0, weights: [])]
        for i in 1..<(cf.count - 1) {
            switch span(i) {
            case .single(let j):
                bands.append(Band(start: j, weights: [1]))
            case .span(let range):
                bands.append(Band(start: range.lowerBound, weights: range.map { j in
                    let x = f(j)
                    if x > cf[i - 1] && x < cf[i] { return (x - cf[i - 1]) / (cf[i] - cf[i - 1]) }
                    if x > cf[i] && x < cf[i + 1] { return (cf[i + 1] - x) / (cf[i + 1] - cf[i]) }
                    return 0
                }))
            }
        }
        return bands
    }

    /// scipy's symmetric Blackman-Harris window.
    static let window: [Double] = (0..<windowLength).map { n in
        let x = -Double.pi + Double(n) * (2 * .pi / Double(windowLength - 1))
        return 0.35875 + 0.48829 * cos(x) + 0.14128 * cos(2 * x) + 0.01168 * cos(3 * x)
    }

    /// Frames for `samples` samples: one every hop, from the first hop up to the last.
    static func frameCount(samples: Int) -> Int {
        max(0, (samples + hop - 1) / hop - 1)
    }

    /// The three maps before the log and normalisation, bin-major (`map[bin * frames + frame]`).
    struct Maps {
        var frames: Int
        var spectrum: [Float]
        var gcos: [Float]
        var cepstrum: [Float]
    }

    private let transform = Bluestein(count: CFP.fftLength)
    private let n = CFP.fftLength
    private let re, im, reversedRe, reversedIm, scratch1, scratch2, a, b: UnsafeMutablePointer<Double>
    private let exponent24, exponent60: [Double]

    init() {
        let n = Self.fftLength
        func buffer() -> UnsafeMutablePointer<Double> {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: n)
            pointer.initialize(repeating: 0, count: n)
            return pointer
        }
        (re, im, reversedRe, reversedIm) = (buffer(), buffer(), buffer(), buffer())
        (scratch1, scratch2, a, b) = (buffer(), buffer(), buffer(), buffer())
        exponent24 = [Double](repeating: 0.24, count: n)
        exponent60 = [Double](repeating: 0.6, count: n)
    }

    deinit {
        for pointer in [re, im, reversedRe, reversedIm, scratch1, scratch2, a, b] { pointer.deallocate() }
    }

    /// The maps for mono 44.1 kHz audio. Frame c is centred on sample 256(c + 1) − 1 and,
    /// as in `cfp.py`, its window is cut short where the audio ends.
    func maps(_ samples: UnsafeBufferPointer<Float>) -> Maps {
        let frames = Self.frameCount(samples: samples.count)
        var maps = Maps(frames: frames,
                        spectrum: [Float](repeating: 0, count: Self.binCount * frames),
                        gcos: [Float](repeating: 0, count: Self.binCount * frames),
                        cepstrum: [Float](repeating: 0, count: Self.binCount * frames))
        let scale = 1 / Double(n).squareRoot()
        // Frames go in pairs, one as the real part and one as the imaginary part of each
        // transform, since every layer's input is real.
        for first in stride(from: 0, to: frames, by: 2) {
            let pair = min(2, frames - first)
            place(frame: first, of: samples, into: re)
            if pair == 2 { place(frame: first + 1, of: samples, into: im) } else { vDSP_vclrD(im, 1, vDSP_Length(n)) }

            // The spectrum's magnitudes to the power 0.24.
            transform.transform(re, im)
            magnitudes()
            power(a, exponent24); power(b, exponent24)
            for k in 0..<pair { apply(Self.spectrumBands, to: k == 0 ? a : b, into: &maps.spectrum, frame: first + k, frames: frames) }

            // The cepstrum: the real part of the spectrum's transform.
            re.update(from: a, count: n); im.update(from: b, count: n)
            transform.transform(re, im)
            realParts(scale: scale)
            nonlinear(a, cutoff: Self.cepstrumCutoff, exponent: exponent60)
            nonlinear(b, cutoff: Self.cepstrumCutoff, exponent: exponent60)
            for k in 0..<pair { apply(Self.quefrencyBands, to: k == 0 ? a : b, into: &maps.cepstrum, frame: first + k, frames: frames) }

            // The generalized cepstrum of the spectrum: the cepstrum's transform, likewise.
            re.update(from: a, count: n); im.update(from: b, count: n)
            transform.transform(re, im)
            realParts(scale: scale)
            nonlinear(a, cutoff: Self.spectrumCutoff, exponent: nil)
            nonlinear(b, cutoff: Self.spectrumCutoff, exponent: nil)
            for k in 0..<pair { apply(Self.spectrumBands, to: k == 0 ? a : b, into: &maps.gcos, frame: first + k, frames: frames) }
        }
        return maps
    }

    /// Writes frame `frame`'s windowed samples into `buffer`, wrapped around index 0. The
    /// window runs from 1,024 samples before the centre to 1,023 after; `cfp.py` indexes the
    /// window one short, so the first weight is the window's last.
    private func place(frame: Int, of samples: UnsafeBufferPointer<Float>, into buffer: UnsafeMutablePointer<Double>) {
        vDSP_vclrD(buffer, 1, vDSP_Length(n))
        let centre = Self.hop * (frame + 1) - 1
        let half = (Self.windowLength - 1) / 2
        let taus = -min(half, centre)..<min(half, samples.count - 1 - centre)
        let window = Self.window
        var norm = 0.0
        for tau in taus {
            let weight = window[(half - 1 + tau + Self.windowLength) % Self.windowLength]
            norm += weight * weight
        }
        norm = norm.squareRoot()
        for tau in taus {
            let weight = window[(half - 1 + tau + Self.windowLength) % Self.windowLength]
            buffer[(n + tau) % n] = Double(samples[centre + tau]) * weight / norm
        }
    }

    /// Fills `reversedRe` and `reversedIm` with the transform at -k (index (n − k) mod n).
    private func reverse() {
        reversedRe[0] = re[0]; reversedIm[0] = im[0]
        (reversedRe + 1).update(from: re + 1, count: n - 1)
        (reversedIm + 1).update(from: im + 1, count: n - 1)
        vDSP_vrvrsD(reversedRe + 1, 1, vDSP_Length(n - 1))
        vDSP_vrvrsD(reversedIm + 1, 1, vDSP_Length(n - 1))
    }

    /// Splits the transform of (real part + i·imaginary part) into the magnitudes of the
    /// two inputs' own transforms, in `a` and `b`: A[k] = (Z[k] + Z*[−k]) / 2 and
    /// B[k] = (Z[k] − Z*[−k]) / 2i.
    private func magnitudes() {
        reverse()
        let length = vDSP_Length(n)
        var half = 0.5
        // vDSP_vsubD(B, A, C) is C = A − B.
        vDSP_vaddD(re, 1, reversedRe, 1, scratch1, 1, length)
        vDSP_vsubD(reversedIm, 1, im, 1, scratch2, 1, length)
        vDSP_vdistD(scratch1, 1, scratch2, 1, a, 1, length)
        vDSP_vsmulD(a, 1, &half, a, 1, length)
        vDSP_vaddD(im, 1, reversedIm, 1, scratch1, 1, length)
        vDSP_vsubD(re, 1, reversedRe, 1, scratch2, 1, length)
        vDSP_vdistD(scratch1, 1, scratch2, 1, b, 1, length)
        vDSP_vsmulD(b, 1, &half, b, 1, length)
    }

    /// Splits the transform likewise into the real parts of the two inputs' transforms, times `scale`.
    private func realParts(scale: Double) {
        reverse()
        let length = vDSP_Length(n)
        var factor = scale / 2
        vDSP_vaddD(re, 1, reversedRe, 1, a, 1, length)
        vDSP_vsmulD(a, 1, &factor, a, 1, length)
        vDSP_vaddD(im, 1, reversedIm, 1, b, 1, length)
        vDSP_vsmulD(b, 1, &factor, b, 1, length)
    }

    /// `nonlinear_func`: negatives and both ends cleared, then raised to `exponent` (1 when nil).
    private func nonlinear(_ x: UnsafeMutablePointer<Double>, cutoff: Int, exponent: [Double]?) {
        var zero = 0.0
        vDSP_vthrD(x, 1, &zero, x, 1, vDSP_Length(n))
        vDSP_vclrD(x, 1, vDSP_Length(cutoff))
        vDSP_vclrD(x + n - cutoff, 1, vDSP_Length(cutoff))
        if let exponent { power(x, exponent) }
    }

    private func power(_ x: UnsafeMutablePointer<Double>, _ exponent: [Double]) {
        var count = Int32(n)
        vvpow(x, exponent, x, &count)
    }

    private func apply(_ bands: [Band], to vector: UnsafeMutablePointer<Double>, into map: inout [Float], frame: Int, frames: Int) {
        for (row, band) in bands.enumerated() where !band.weights.isEmpty {
            var sum = 0.0
            vDSP_dotprD(vector + band.start, 1, band.weights, 1, &sum, vDSP_Length(band.weights.count))
            map[row * frames + frame] = Float(sum)
        }
    }

    /// MSNet's input from the maps: each map as log(1 + x), scaled to 0...1 over all its
    /// values, in channel, bin, frame order.
    static func features(_ maps: Maps) -> [Float] {
        var features: [Float] = []
        features.reserveCapacity(3 * binCount * maps.frames)
        for map in [maps.spectrum, maps.gcos, maps.cepstrum] {
            var logged = [Float](repeating: 0, count: map.count)
            var count = Int32(map.count)
            map.withUnsafeBufferPointer { vvlog1pf(&logged, $0.baseAddress!, &count) }
            let low = vDSP.minimum(logged), high = vDSP.maximum(logged)
            let range = high > low ? high - low : 1
            features += vDSP.multiply(1 / range, vDSP.add(-low, logged))
        }
        return features
    }
}

/// A forward DFT of any length, by Bluestein's algorithm on vDSP's power-of-two FFT: the
/// DFT becomes a convolution with a chirp, done with two FFTs of at least twice the length.
final class Bluestein {
    let count: Int
    private let log2Size: vDSP_Length
    private let size: Int
    private let setup: FFTSetupD
    /// exp(−iπk²/count), for k below `count`.
    private let chirpRe, chirpIm: UnsafeMutablePointer<Double>
    /// The transformed conjugate chirp, with the inverse FFT's 1 / size folded in.
    private let filterRe, filterIm: UnsafeMutablePointer<Double>
    private let workRe, workIm: UnsafeMutablePointer<Double>

    init(count: Int) {
        self.count = count
        var log2 = 0
        while 1 << log2 < 2 * count - 1 { log2 += 1 }
        log2Size = vDSP_Length(log2)
        size = 1 << log2
        setup = vDSP_create_fftsetupD(log2Size, FFTRadix(kFFTRadix2))!
        func buffer(_ capacity: Int) -> UnsafeMutablePointer<Double> {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
        (chirpRe, chirpIm) = (buffer(count), buffer(count))
        (filterRe, filterIm, workRe, workIm) = (buffer(size), buffer(size), buffer(size), buffer(size))
        for k in 0..<count {
            // k² mod 2·count keeps the angle exact for large k.
            let angle = Double.pi * Double((k * k) % (2 * count)) / Double(count)
            chirpRe[k] = cos(angle)
            chirpIm[k] = -sin(angle)
            filterRe[k] = chirpRe[k]
            filterIm[k] = -chirpIm[k]
            if k > 0 {
                filterRe[size - k] = chirpRe[k]
                filterIm[size - k] = -chirpIm[k]
            }
        }
        var filter = DSPDoubleSplitComplex(realp: filterRe, imagp: filterIm)
        vDSP_fft_zipD(setup, &filter, 1, log2Size, FFTDirection(kFFTDirection_Forward))
        var scale = 1 / Double(size)
        vDSP_vsmulD(filterRe, 1, &scale, filterRe, 1, vDSP_Length(size))
        vDSP_vsmulD(filterIm, 1, &scale, filterIm, 1, vDSP_Length(size))
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
        for pointer in [chirpRe, chirpIm, filterRe, filterIm, workRe, workIm] { pointer.deallocate() }
    }

    /// Replaces re + i·im, each `count` long, with its DFT.
    func transform(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
        var x = DSPDoubleSplitComplex(realp: re, imagp: im)
        var chirp = DSPDoubleSplitComplex(realp: chirpRe, imagp: chirpIm)
        var filter = DSPDoubleSplitComplex(realp: filterRe, imagp: filterIm)
        var work = DSPDoubleSplitComplex(realp: workRe, imagp: workIm)
        vDSP_zvmulD(&x, 1, &chirp, 1, &work, 1, vDSP_Length(count), 1)
        vDSP_vclrD(workRe + count, 1, vDSP_Length(size - count))
        vDSP_vclrD(workIm + count, 1, vDSP_Length(size - count))
        vDSP_fft_zipD(setup, &work, 1, log2Size, FFTDirection(kFFTDirection_Forward))
        vDSP_zvmulD(&work, 1, &filter, 1, &work, 1, vDSP_Length(size), 1)
        vDSP_fft_zipD(setup, &work, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
        vDSP_zvmulD(&work, 1, &chirp, 1, &x, 1, vDSP_Length(count), 1)
    }
}
