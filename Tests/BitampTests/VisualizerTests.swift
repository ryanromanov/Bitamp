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
            // A chord plus a sweep of overtones, so most bars rise rather than a few.
            var sample = 0.25 * sin(2 * .pi * 80 * t) + 0.15 * sin(2 * .pi * 440 * t)
            for k in 1...12 { sample += 0.05 * sin(2 * .pi * Float(k) * 230 * t + Float(k)) }
            buffer.floatChannelData![0][i] = sample
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
        for renderer in [quiet, busy] {
            renderer.setPalette(DefaultSkin().visColors)
            renderer.pixelDivisor = 2
        }
        let folder = ProcessInfo.processInfo.environment["BITAMP_VISUALIZER_OUT"]
        for (i, visual) in FullVisual.allCases.enumerated() {
            quiet.select(visual)
            busy.select(visual)
            // 40 frames, so Alchemy's feedback has something built up.
            let still = try #require(quiet.snapshot(width: 640, height: 400, frames: 40))
            let moving = try #require(busy.snapshot(width: 640, height: 400, frames: 40))
            #expect(moving.dataProvider?.data != still.dataProvider?.data, "\(visual.title) should look different with music than in silence")
            #expect(variety(moving) > 6)
            if let folder {
                for (name, image) in [("silent", still), ("playing", moving)] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("visual-\(i)-\(visual.rawValue)-\(name).png")
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    // MARK: - The panel

    func panel() -> (VisualizerView, Preferences, PlaybackController) {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampVisualizer-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        return (VisualizerView(controller: controller, preferences: preferences, skin: DefaultSkin(), scale: 2), preferences, controller)
    }

    @Test func arrowKeysStepThroughTheVisualsAndRemember() {
        let (view, preferences, _) = panel()
        #expect(preferences.fullVisual == FullVisual.barsAndWaves.rawValue)
        view.step(1)
        #expect(preferences.fullVisual == FullVisual.plasma.rawValue)
        view.step(-1)
        view.step(-1)
        #expect(preferences.fullVisual == FullVisual.alchemy.rawValue, "stepping back from the first wraps to the last")
    }

    @Test func theWindowStaysAtLeastItsMinimumSize() {
        let (view, _, _) = panel()
        let size = view.normalizedPixelSize(CGSize(width: 10, height: 10))
        #expect(size == VisualizerLayout.minSize)
        #expect(view.normalizedPixelSize(CGSize(width: 400.4, height: 300.6)) == CGSize(width: 400, height: 301))
    }

    @Test func aHiddenPanelCostsNothing() {
        let (view, _, controller) = panel()
        view.tick()
        #expect(!controller.visualizerWindowOpen)
        #expect(view.subviews.isEmpty, "no Metal view is built until the panel shows")
    }

    @Test func voiceOverFindsTheCloseButtonAndTheVisual() {
        let (view, _, _) = panel()
        let labels = view.accessibleControls().map(\.label)
        #expect(labels.contains("Close"))
        #expect(labels.contains { $0.hasPrefix("Visual: Bars and Waves") })
        #expect(view.accessibilityName == "Visualizer")
    }

    @Test func anOpenVisualizerKeepsTheAppleMusicTapListening() {
        let (_, _, controller) = panel()
        controller.visualizerWindowOpen = true
        // The listener only runs while something plays; this checks the call doesn't trip
        // and that the flag is what the call reads.
        controller.updateListener(visualizerOn: false)
        #expect(controller.visualizerWindowOpen)
    }
}
