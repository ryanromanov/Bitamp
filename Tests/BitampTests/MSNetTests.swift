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

    @Test func vocalLineMakesNotes() {
        var line = VocalLine()
        // Vibrato holds a note; a 2-tick gap is bridged; a 1-tick note after silence goes.
        let pitches: [Double?] = [60.1, 60.3, 59.6, nil, nil] + [Double?](repeating: 62, count: 4)
            + [Double?](repeating: nil, count: 5) + [67] + [Double?](repeating: 60, count: 5)
        let expected: [Int?] = [Int?](repeating: 60, count: 5) + [Int?](repeating: 62, count: 7)
            + [nil, nil, nil] + [Int?](repeating: 60, count: 5)
        #expect(line.notes(pitches, count: pitches.count) == expected)

        // A short note between two of the same joins them.
        var other = VocalLine()
        let blip: [Double?] = [62, 62, 62, 62, 63, 63, 62, 62, 62, 62]
        #expect(other.notes(blip, count: blip.count) == [Int?](repeating: 62, count: 10))

        // In stretches with lookahead, the same notes.
        var streamed = VocalLine()
        let first = streamed.notes(Array(pitches[0..<17]), count: 9)
        let rest = streamed.notes(Array(pitches[9...]), count: 11)
        #expect(first + rest == expected)
    }

    @Test func vocalReplacesTheLeadWhileItSounds() {
        var arranger = ChipArranger()
        var moment = ChipMoment()
        moment.lead = 72
        moment.leadLevel = 10
        moment.onsets = ChipMoment.leadOnset
        let sung = arranger.addVocal(67, to: moment)
        #expect(sung.lead == 67 && sung.leadLevel == 10)
        #expect(sung.chord == (72, 0, 0) && sung.chordLevel == 7)
        #expect(sung.onsets == ChipMoment.leadOnset | ChipMoment.chordOnset)
        let held = arranger.addVocal(67, to: ChipMoment())
        #expect(held.lead == 67 && held.leadLevel == ChipArranger.vocalLevel && held.onsets == 0)
        #expect(arranger.addVocal(nil, to: moment) == moment)
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
        compare(bins, pythonBins, frames: frames, took: took, label: "whole clip")

        // As the app runs it: in stretches like Basic Pitch's segments (2 and 6 windows,
        // about 570 and 1,700 frames), each scaled by the peaks within 10 s of it.
        for stretch in [570, 1_700] {
            let tracker = VocalTracker(model: model, length: samples.count) { start, count, out in
                for i in 0..<count {
                    let index = start + i
                    out[i] = index >= 0 && index < samples.count ? samples[index] : 0
                }
            }
            var stretched: [Int] = []
            let began = Date()
            for first in stride(from: 0, to: frames, by: stretch) {
                stretched += try tracker.bins(frames: first..<min(frames, first + stretch))
            }
            compare(stretched, pythonBins, frames: frames, took: Date().timeIntervalSince(began), label: "\(stretch)-frame stretches")
        }
    }

    func compare(_ bins: [Int], _ pythonBins: [Int], frames: Int, took: Double, label: String) {
        let voicing = zip(bins, pythonBins).filter { ($0 > 0) == ($1 > 0) }.count
        let coVoiced = zip(bins, pythonBins).filter { $0 > 0 && $1 > 0 }
        let close = coVoiced.filter { abs($0 - $1) <= 2 }.count
        print("MSNet \(label): \(frames) frames, \(String(format: "%.2f", took)) s, voicing agree \(100 * voicing / frames)%, "
              + "within 40 cents \(100 * close / max(1, coVoiced.count))% of \(coVoiced.count) co-voiced")
        #expect(Double(voicing) / Double(frames) > 0.97)
        #expect(Double(close) / Double(max(1, coVoiced.count)) > 0.97)
    }
}

/// How MSNet's feature peaks vary within and between songs, for choosing how to normalise:
/// BITAMP_PEAKS_FILES=<file>:<file>... Prints, per song, the whole song's peaks, what scans
/// of one frame in 4 and 16 find, and the spread of 20-second clips' peaks.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_PEAKS_FILES"] != nil))
struct MSNetPeakSurvey {
    @Test func survey() throws {
        for path in ProcessInfo.processInfo.environment["BITAMP_PEAKS_FILES"]!.split(separator: ":") {
            let reader = try BasicPitchReader(url: URL(fileURLWithPath: String(path)), sampleRate: CFP.sampleRate)
            let cfp = CFP()
            let frames = CFP.frameCount(samples: reader.length)
            // Each frame's largest log(1 + x) per map.
            var perFrame = [[Float]](repeating: [], count: 3)
            let chunk = 4_096
            var audio = [Float](repeating: 0, count: CFP.hop * (chunk + 1) + CFP.windowLength)
            let half = (CFP.windowLength - 1) / 2
            for first in stride(from: 0, to: frames, by: chunk) {
                let count = min(chunk, frames - first)
                let start = CFP.hop * first - half
                try audio.withUnsafeMutableBufferPointer { try reader.read(from: start, count: $0.count, into: $0.baseAddress!) }
                let centres = (0..<count).map { CFP.hop * (first + $0 + 1) - 1 - start }
                let maps = audio.withUnsafeBufferPointer { cfp.maps($0, centres: centres) }
                for (channel, map) in [maps.spectrum, maps.gcos, maps.cepstrum].enumerated() {
                    for frame in 0..<count {
                        var top: Float = 0
                        for bin in 0..<CFP.binCount { top = max(top, map[bin * count + frame]) }
                        perFrame[channel].append(log1p(top))
                    }
                }
            }
            func fmt(_ values: [Float]) -> String { values.map { String(format: "%.3f", $0) }.joined(separator: " ") }
            let whole = perFrame.map { $0.max() ?? 0 }
            let scan4 = perFrame.map { s in stride(from: 0, to: s.count, by: 4).map { s[$0] }.max() ?? 0 }
            let scan16 = perFrame.map { s in stride(from: 0, to: s.count, by: 16).map { s[$0] }.max() ?? 0 }
            // 20-second clips, every 10 s.
            let clip = Int(20 * CFP.sampleRate) / CFP.hop, step = clip / 2
            var clips = [[Float]](repeating: [], count: 3)
            for first in stride(from: 0, to: max(1, frames - clip), by: step) {
                for channel in 0..<3 { clips[channel].append(perFrame[channel][first..<min(frames, first + clip)].max() ?? 0) }
            }
            print("PEAKS \((path as NSString).lastPathComponent): \(String(format: "%.0f", Double(reader.length) / CFP.sampleRate)) s")
            print("PEAKS   whole \(fmt(whole)) | scan/4 \(fmt(scan4)) | scan/16 \(fmt(scan16))")
            for channel in 0..<3 {
                let sorted = clips[channel].sorted()
                print("PEAKS   clip ch\(channel): min \(fmt([sorted.first ?? 0])) median \(fmt([sorted[sorted.count / 2]])) max \(fmt([sorted.last ?? 0]))")
            }
        }
    }
}
