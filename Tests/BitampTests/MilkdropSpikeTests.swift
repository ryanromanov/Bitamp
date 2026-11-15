import AppKit
import Foundation
import Metal
import Testing
@testable import BitampKit

/// Draws presets from a folder to PNGs, for looking at. Runs only when BITAMP_MILK_PRESETS names
/// a folder of `.milk` files; BITAMP_MILK_OUT says where the pictures go.
@MainActor @Suite struct MilkdropSpikeTests {
    private static let presets = ProcessInfo.processInfo.environment["BITAMP_MILK_PRESETS"]

    /// Music-like numbers: a kick twice a second over a steady wash, and a wobbling scope.
    private func audio(at time: Double) -> MilkAudio {
        // A kick on every beat at 2 Hz, a snare on the off-beats, hats flickering, and a bass
        // line that changes every few seconds, so each band moves the way real music's do.
        let beat = (time * 2).truncatingRemainder(dividingBy: 1)
        let kick = Float(max(0, 1 - beat * 4))
        let snare = Float(max(0, 1 - ((time * 2 + 0.5).truncatingRemainder(dividingBy: 1)) * 5))
        let phrase = Float(0.5 + 0.5 * sin(time * 0.7))
        var bars = [Float](repeating: 0, count: 19)
        for band in 0..<19 {
            let f = Float(band)
            var level: Float = 0.2 + 0.15 * phrase * (1 - f / 25)
            if band < 5 {
                level += kick * 0.6
            } else if band < 13 {
                let wobble: Float = 0.1 * Float(sin(time * Double(1.3 + f)))
                level += snare * 0.4 + wobble
            } else {
                let flutter: Float = 0.25 * Float(max(0, sin(time * Double(23 + f * 3))))
                level += flutter * (0.4 + phrase)
            }
            bars[band] = max(0, min(1, level))
        }
        let cycles = 2 + 3 * Double(phrase)
        let loudness = 0.4 + 0.6 * Double(kick)
        let wave = (0..<76).map { i -> Float in
            let t = Double(i) / 76
            let main: Double = 0.5 * sin(t * 2 * .pi * cycles + time * 6) * loudness
            let grit: Double = 0.2 * sin(t * 2 * .pi * 11 + time * 17)
            return Float(main + grit)
        }
        return MilkAudio(bars: bars, waveform: wave)
    }

    private func write(_ texture: MTLTexture, to url: URL) {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        guard let image = CGDataProvider(data: Data(pixels) as CFData).flatMap({
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @Test(.enabled(if: MilkdropSpikeTests.presets != nil)) func drawsPresets() throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(Self.presets))
        let out = URL(fileURLWithPath: environment["BITAMP_MILK_OUT"] ?? NSTemporaryDirectory())
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try #require(MilkdropEngine(device: device))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 480, height: 360, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        for file in files {
            let preset = try #require(MilkPreset(contentsOf: file))
            let warp = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("warp.metal"), encoding: .utf8)
            let composite = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("comp.metal"), encoding: .utf8)
            engine.load(preset, warpSource: warp, compositeSource: composite)
            engine.skipping = Set((environment["BITAMP_MILK_SKIP"] ?? "").split(separator: ",").map(String.init))
            let name = file.deletingPathExtension().lastPathComponent
            FileHandle.standardError.write(Data("\(name): \(engine.problems.isEmpty ? "compiled" : engine.problems.joined(separator: "; "))\n".utf8))
            let started = Date()
            for frame in 1...300 {
                let time = Double(frame) / 60
                engine.render(audio: audio(at: time), time: time, deltaTime: 1.0 / 60, into: output)
                if [20, 60, 150, 300].contains(frame) { write(output, to: out.appendingPathComponent("\(name)-\(frame).png")) }
                if [2, 20].contains(frame) {
                    let names = ["bass", "mid", "treb", "bass_att", "ib_r", "ib_g", "ib_b", "ob_r", "ob_g", "ob_b", "zoom", "decay", "wave_r", "wave_g", "wave_b", "wave_a"]
                    FileHandle.standardError.write(Data(("  vars f\(frame): " + names.map { "\($0)=\(String(format: "%.3f", engine.frameValue($0)))" }.joined(separator: " ") + "\n").utf8))
                }
                if [1, 2, 5, 20, 100, 300].contains(frame) {
                    var px = [UInt8](repeating: 0, count: 480 * 360 * 4)
                    output.getBytes(&px, bytesPerRow: 480 * 4, from: MTLRegionMake2D(0, 0, 480, 360), mipmapLevel: 0)
                    var sum = [0, 0, 0]
                    for i in stride(from: 0, to: px.count, by: 4) { sum[0] += Int(px[i + 2]); sum[1] += Int(px[i + 1]); sum[2] += Int(px[i]) }
                    FileHandle.standardError.write(Data("  frame \(frame) mean rgb \(sum.map { $0 / (480 * 360) })\n".utf8))
                }
            }
            let ms = Date().timeIntervalSince(started) / 300 * 1000
            FileHandle.standardError.write(Data("\(name): \(String(format: "%.2f", ms)) ms a frame\n".utf8))
        }
    }

    /// The same presets through Bitamp's look: drawn small, then either dithered to a few levels
    /// per colour (as Alchemy is) or run through the skin's 16-step analyzer ramp by brightness.
    /// Writes one strip per preset: as drawn, dithered, palette; each blown up with no smoothing.
    @Test(.enabled(if: MilkdropSpikeTests.presets != nil && ProcessInfo.processInfo.environment["BITAMP_MILK_LOOK"] != nil))
    func drawsPresetsInBitampsLook() throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(Self.presets))
        let out = URL(fileURLWithPath: environment["BITAMP_MILK_OUT"] ?? NSTemporaryDirectory())
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try #require(MilkdropEngine(device: device))
        let width = 200, height = 150, scale = 2
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: descriptor))
        // The classic skin's analyzer ramp, green at the bottom to red at the top.
        let ramp: [(Float, Float, Float)] = [(24, 132, 8), (41, 148, 0), (49, 156, 8), (57, 181, 16), (50, 190, 16), (41, 206, 16), (41, 214, 8), (74, 214, 8),
                                             (123, 214, 8), (165, 214, 8), (214, 214, 0), (222, 198, 0), (222, 165, 0), (222, 132, 0), (222, 90, 0), (231, 41, 24)]
        let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        for file in files {
            let preset = try #require(MilkPreset(contentsOf: file))
            let warp = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("warp.metal"), encoding: .utf8)
            let composite = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("comp.metal"), encoding: .utf8)
            engine.load(preset, warpSource: warp, compositeSource: composite)
            let name = file.deletingPathExtension().lastPathComponent
            for frame in 1...150 {
                let time = Double(frame) / 60
                engine.render(audio: audio(at: time), time: time, deltaTime: 1.0 / 60, into: output)
                guard frame == 150 else { continue }
                var px = [UInt8](repeating: 0, count: width * height * 4)
                output.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                var dithered = px, palette = px
                for y in 0..<height { for x in 0..<width {
                    let i = (y * width + x) * 4
                    let threshold = (bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16 - 0.5
                    let levels: Float = 6
                    for c in 0..<3 {
                        let v = Float(px[i + c]) / 255
                        dithered[i + c] = UInt8(max(0, min(1, floor(v * (levels - 1) + 0.5 + threshold) / (levels - 1))) * 255)
                    }
                    let b = Float(px[i + 2]) * 0.3 + Float(px[i + 1]) * 0.59 + Float(px[i]) * 0.11
                    let t = max(0, min(1, b / 255 + threshold / 8))
                    if t < 0.04 { palette[i] = 0; palette[i + 1] = 0; palette[i + 2] = 0 } else {
                        let r = ramp[min(15, Int(t * 15.99))]
                        palette[i + 2] = UInt8(r.0); palette[i + 1] = UInt8(r.1); palette[i] = UInt8(r.2)
                    }
                } }
                let stripWidth = width * 3 * scale, stripHeight = height * scale
                var strip = [UInt8](repeating: 255, count: stripWidth * stripHeight * 4)
                for (panel, source) in [px, dithered, palette].enumerated() {
                    for y in 0..<stripHeight { for x in 0..<(width * scale) {
                        let from = ((y / scale) * width + x / scale) * 4
                        let to = (y * stripWidth + panel * width * scale + x) * 4
                        for c in 0..<4 { strip[to + c] = source[from + c] }
                    } }
                }
                let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
                if let image = CGDataProvider(data: Data(strip) as CFData).flatMap({
                    CGImage(width: stripWidth, height: stripHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stripWidth * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                }) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-look.png"))
                }
            }
        }
    }
}

/// Compiles Metal sources that came out of the shader conversion, for counting what survives.
/// Runs only when BITAMP_MILK_MSL names a folder of `.metal` files.
@MainActor @Suite struct MilkdropShaderCompileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITAMP_MILK_MSL"] != nil))
    func compilesConvertedShaders() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BITAMP_MILK_MSL"]))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "metal" }.sorted { $0.path < $1.path }
        var passed = 0
        var failures: [String: Int] = [:]
        var samples: [String: String] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            do {
                _ = try device.makeLibrary(source: source, options: nil)
                passed += 1
            } catch {
                let text = (error as NSError).localizedDescription; if ProcessInfo.processInfo.environment["BITAMP_MILK_VERBOSE"] != nil { FileHandle.standardError.write(Data((text.prefix(900) + "\n").utf8)) }
                var key = "?"
                if let range = text.range(of: "error: [^\\n]*", options: .regularExpression) {
                    key = String(text[range]).replacingOccurrences(of: "'[^']*'", with: "'_'", options: .regularExpression)
                }
                failures[String(key.prefix(110)), default: 0] += 1
                samples[String(key.prefix(110))] = file.lastPathComponent
            }
        }
        FileHandle.standardError.write(Data("compiled \(passed) of \(files.count)\n".utf8))
        for (message, count) in failures.sorted(by: { $0.value > $1.value }).prefix(12) {
            FileHandle.standardError.write(Data("  \(count)  \(message)   [\(samples[message] ?? "")]\n".utf8))
        }
    }
}
