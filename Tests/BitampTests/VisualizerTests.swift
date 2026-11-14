import AVFoundation
import AppKit
import MetalKit
import Testing
@testable import BitampKit

/// The full-window visualizer's shaders compile and draw something that follows the audio.
@MainActor
@Suite struct VisualizerTests {
    /// A chord of a few sines, so several bars rise.
    func playing(_ analyzer: SpectrumAnalyzer) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        for i in 0..<4096 {
            let t = Float(i) / 44_100
            buffer.floatChannelData![0][i] = 0.25 * sin(2 * .pi * 80 * t) + 0.15 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 3000 * t)
        }
        for _ in 0..<20 {
            analyzer.process(buffer)
            analyzer.advance()
        }
    }

    func variety(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return colors.count
    }

    @Test func everyVisualDrawsAndFollowsTheAudio() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let silent = SpectrumAnalyzer()
        let loud = SpectrumAnalyzer()
        playing(loud)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), device: device)
        let quiet = try #require(VisualizerRenderer(view: view, analyzer: silent))
        let busy = try #require(VisualizerRenderer(view: view, analyzer: loud))
        #expect(busy.count == VisualizerShaders.visuals.count)
        let folder = ProcessInfo.processInfo.environment["BITAMP_VISUALIZER_OUT"]
        for i in 0..<busy.count {
            quiet.select(i)
            busy.select(i)
            let still = try #require(quiet.snapshot(width: 640, height: 400, time: 5))
            let moving = try #require(busy.snapshot(width: 640, height: 400, time: 5))
            #expect(variety(moving) > variety(still), "visual \(i) should show more with music than in silence")
            #expect(variety(moving) > 20)
            if let folder {
                for (name, image) in [("silent", still), ("playing", moving)] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("visual-\(i)-\(name).png")
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
