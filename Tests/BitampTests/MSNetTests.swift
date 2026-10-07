import Foundation
import Testing
@testable import BitampKit

@Suite struct MSNetTests {
    @Test(arguments: [30, 1_000, 1_323])
    func bluesteinMatchesADirectDFT(count: Int) {
        var generator = SystemRandomNumberGenerator()
        let inputRe = (0..<count).map { _ in Double.random(in: -1...1, using: &generator) }
        let inputIm = (0..<count).map { _ in Double.random(in: -1...1, using: &generator) }
        var re = inputRe, im = inputIm
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in Bluestein(count: count).transform(r.baseAddress!, i.baseAddress!) }
        }
        var worst = 0.0
        for k in 0..<count {
            var sumRe = 0.0, sumIm = 0.0
            for j in 0..<count {
                let angle = -2 * Double.pi * Double((j * k) % count) / Double(count)
                sumRe += inputRe[j] * cos(angle) - inputIm[j] * sin(angle)
                sumIm += inputRe[j] * sin(angle) + inputIm[j] * cos(angle)
            }
            worst = max(worst, abs(sumRe - re[k]), abs(sumIm - im[k]))
        }
        #expect(worst < 1e-9)
    }

    @Test func tablesMatchCFP() {
        #expect(CFP.centralFrequencies.count == 321)
        #expect(CFP.spectrumBands.count == CFP.binCount)
        #expect(CFP.quefrencyBands.count == CFP.binCount)
        #expect(CFP.spectrumBands.allSatisfy { $0.start + $0.weights.count <= CFP.spectrumBins })
        #expect(CFP.quefrencyBands.allSatisfy { $0.start + $0.weights.count <= CFP.quefrencyBins })
        #expect(CFP.frameCount(samples: 44_100) == 172)
        #expect(CFP.frameCount(samples: 512) == 1)
    }

    @Test func modelRuns() throws {
        let model = try #require(MSNet.shared)
        let seconds = 1.0
        let samples = (0..<Int(seconds * CFP.sampleRate)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / CFP.sampleRate)) }
        let maps = samples.withUnsafeBufferPointer { CFP().maps($0) }
        let bins = try model.pitchBins(features: CFP.features(maps), frames: maps.frames)
        #expect(bins.count == maps.frames)
        #expect(bins.allSatisfy { (0..<MSNet.outputBins).contains($0) })
    }
}

/// Compares the Swift CFP and MSNet with Python's on a clip that
/// `scripts/msnet/dump-features.py` wrote: BITAMP_CFP_DUMP=<file.cfp>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_CFP_DUMP"] != nil))
struct MSNetDumpTests {
    @Test func matchesPython() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["BITAMP_CFP_DUMP"]!))
        let (sampleCount, frames) = data.withUnsafeBytes { (Int($0.load(as: Int32.self)), Int($0.load(fromByteOffset: 4, as: Int32.self))) }
        func floats(at offset: Int, count: Int) -> [Float] {
            data.withUnsafeBytes { raw in (0..<count).map { raw.loadUnaligned(fromByteOffset: offset + 4 * $0, as: Float.self) } }
        }
        let mapSize = CFP.binCount * frames
        var offset = 8
        let samples = floats(at: offset, count: sampleCount); offset += 4 * sampleCount
        let python = CFP.Maps(frames: frames,
                              spectrum: floats(at: offset, count: mapSize),
                              gcos: floats(at: offset + 4 * mapSize, count: mapSize),
                              cepstrum: floats(at: offset + 8 * mapSize, count: mapSize))
        offset += 12 * mapSize
        let pythonBins = data.withUnsafeBytes { raw in (0..<frames).map { Int(raw.loadUnaligned(fromByteOffset: offset + 4 * $0, as: Int32.self)) } }

        let began = Date()
        let swift = samples.withUnsafeBufferPointer { CFP().maps($0) }
        let took = Date().timeIntervalSince(began)
        #expect(swift.frames == frames)
        let swiftFeatures = CFP.features(swift), pythonFeatures = CFP.features(python)
        for (channel, name) in ["spectrum", "gcos", "cepstrum"].enumerated() {
            let range = (channel * mapSize)..<((channel + 1) * mapSize)
            var worst: Float = 0, total: Float = 0
            for i in range {
                let difference = abs(swiftFeatures[i] - pythonFeatures[i])
                worst = max(worst, difference)
                total += difference
            }
            print("CFP \(name): max diff \(worst), mean diff \(total / Float(mapSize))")
            #expect(worst < 0.01)
        }

        let model = try #require(MSNet.shared)
        var bins: [Int] = []
        for start in stride(from: 0, to: frames, by: 4_096) {
            let count = min(4_096, frames - start)
            guard count >= MSNet.frameRange.lowerBound else { bins += [Int](repeating: 0, count: count); continue }
            var window: [Float] = []
            for row in 0..<(3 * CFP.binCount) { window += swiftFeatures[(row * frames + start)..<(row * frames + start + count)] }
            bins += try model.pitchBins(features: window, frames: count)
        }
        let voicing = zip(bins, pythonBins).filter { ($0 > 0) == ($1 > 0) }.count
        let coVoiced = zip(bins, pythonBins).filter { $0 > 0 && $1 > 0 }
        let close = coVoiced.filter { abs($0 - $1) <= 2 }.count
        print("MSNet: \(frames) frames, CFP \(String(format: "%.2f", took)) s, voicing agree \(100 * voicing / frames)%, "
              + "within 40 cents \(100 * close / max(1, coVoiced.count))% of \(coVoiced.count) co-voiced")
        #expect(Double(voicing) / Double(frames) > 0.97)
        #expect(Double(close) / Double(max(1, coVoiced.count)) > 0.97)
    }
}
