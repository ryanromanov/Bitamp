import CoreML
import Foundation

/// MSNet vocal (Hsieh, Su & Yang, "A Streamlined Encoder/Decoder Architecture for Melody
/// Extraction", ICASSP 2019; github.com/bill317996/Melody-extraction-with-melodic-segnet,
/// MIT): a small network that follows the sung melody's pitch, frame by frame, in `CFP`
/// features. `scripts/msnet/convert.py` made the Core ML package.
///
/// Not for the render thread.
final class MSNet: @unchecked Sendable {
    /// Frames the model takes at once.
    static let frameRange = 64...8_192
    /// Output bins: 0 is "no voice", bin k is `frequency(ofBin: k)`.
    static let outputBins = CFP.binCount + 1

    /// The model, compiled on first use, or nil when it couldn't be loaded.
    static let shared: MSNet? = {
        do {
            return try MSNet()
        } catch {
            NSLog("Bitamp: MSNet is unavailable: \(error)")
            return nil
        }
    }()

    private let model: MLModel
    /// Core ML doesn't promise a model is safe to use from two threads at once.
    private let lock = NSLock()

    init() throws {
        guard let url = BasicPitch.modelURL(path: "MSNet/msnet_vocal.mlpackage") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "msnet_vocal.mlpackage not found"])
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: try BasicPitch.compiledModel(for: url, name: "MSNet"), configuration: configuration)
    }

    static func frequency(ofBin bin: Int) -> Double {
        bin == 0 ? 0 : CFP.centralFrequencies[bin]
    }

    /// The likeliest bin of each frame, for `frames` frames of `CFP.features`.
    func pitchBins(features: [Float], frames: Int) throws -> [Int] {
        precondition(features.count == 3 * CFP.binCount * frames && Self.frameRange.contains(frames))
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: CFP.binCount), NSNumber(value: frames)], dataType: .float32)
        let inputStrides = input.strides.map(\.intValue)
        let destination = input.dataPointer.assumingMemoryBound(to: Float.self)
        features.withUnsafeBufferPointer { source in
            for row in 0..<(3 * CFP.binCount) {
                let channel = row / CFP.binCount, bin = row % CFP.binCount
                (destination + channel * inputStrides[1] + bin * inputStrides[2])
                    .update(from: source.baseAddress! + row * frames, count: frames)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["cfp": input]))
        guard let array = output.featureValue(for: "salience")?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        // Core ML may hand back fp16 even though the model says fp32; this converts either.
        let salience = MLShapedArray<Float>(converting: array).scalars
        var bins = [Int](repeating: 0, count: frames)
        for frame in 0..<frames {
            var best = 0, bestValue = -Float.infinity
            for bin in 0..<Self.outputBins {
                let value = salience[bin * frames + frame]
                if value > bestValue { (best, bestValue) = (bin, value) }
            }
            bins[frame] = best
        }
        return bins
    }
}
