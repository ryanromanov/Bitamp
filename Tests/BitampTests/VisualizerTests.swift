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

    /// How many pixels differ from the top-left one, which is background in every visual here.
    func litPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        let background = rep.colorAt(x: 0, y: 0)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y) != background { count += 1 }
        }
        return count
    }

    @Test func starsAreMadeFromLoudMusicAndNotFromQuietMusic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), device: device)
        let loud = SpectrumAnalyzer()
        playing(loud)
        let quiet = SpectrumAnalyzer()
        for visual in [FullVisual.solarSailing, .starfield] {
            let busy = try #require(VisualizerRenderer(view: view, analyzer: loud))
            let still = try #require(VisualizerRenderer(view: view, analyzer: quiet))
            for renderer in [busy, still] {
                renderer.setPalette(DefaultSkin().visColors)
                renderer.pixelDivisor = 2
                renderer.select(visual)
            }
            let some = litPixels(try #require(busy.snapshot(width: 640, height: 400, frames: 30)))
            let few = litPixels(try #require(still.snapshot(width: 640, height: 400, frames: 30)))
            #expect(few * 4 < some, "\(visual.title): \(few) lit pixels in quiet music against \(some) in loud")
        }
    }

    @Test func manyRowsStillDrawTheStars() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), device: device)
        let analyzer = SpectrumAnalyzer()
        playing(analyzer)
        for visual in [FullVisual.solarSailing, .starfield] {
            let renderer = try #require(VisualizerRenderer(view: view, analyzer: analyzer))
            renderer.setPalette(DefaultSkin().visColors)
            // One screen pixel to a picture pixel on a 640 by 400 target: more rows than the panel's.
            renderer.pixelDivisor = 1
            renderer.select(visual)
            let image = try #require(renderer.snapshot(width: 640, height: 400, frames: 30))
            #expect(litPixels(image) > 200)
            if let folder = ProcessInfo.processInfo.environment["BITAMP_VISUALIZER_OUT"] {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("full-\(visual.rawValue).png"))
            }
        }
    }

    /// A frame whose height isn't a whole number of tiles, like a resized visualizer, must still
    /// have its bottom bar run unbroken to both sides.
    @Test func theBottomBarRunsToTheSidesAtAnyHeight() {
        for skin in [DefaultSkin(), DefaultSkin(theme: .millennium), DefaultSkin(theme: .orb)] as [Skin] {
            for height in 120...150 {
                let size = CGSize(width: 275, height: CGFloat(height))
                let canvas = Canvas(size)
                PanelFrame(skin: skin, size: size, title: "VISUALIZER", active: true).draw(canvas, closePressed: false)
                let rep = NSBitmapImageRep(cgImage: canvas.image())
                let row = height - 4  // Inside the bottom bar.
                // The bar's colour in the middle, against under the sides' columns (the left tile,
                // and the right tile with its scroll groove).
                let middle = rep.colorAt(x: 137, y: row)
                for x in [4, 6, 8, 258, 262, 266, 270] {
                    #expect(rep.colorAt(x: x, y: row) == middle, "row \(row), x \(x), height \(height)")
                }
            }
        }
    }

    @Test func driftFadesThroughThePresetsAndAHeldPresetStays() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), device: device)
        let analyzer = SpectrumAnalyzer()
        playing(analyzer)
        let renderer = try #require(VisualizerRenderer(view: view, analyzer: analyzer))
        renderer.setPalette(DefaultSkin().visColors)
        renderer.pixelDivisor = 2
        renderer.presetSeconds = 0.15
        renderer.fadeSeconds = 0.25
        var names: [String] = []
        renderer.onPreset = { names.append($0) }
        renderer.select(VisualChoice(visual: .presets))
        var images = 0
        for _ in 0..<60 {
            if renderer.snapshot(width: 320, height: 200, frames: 1) != nil { images += 1 }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(images == 60)
        #expect(names.count >= 3, "Drift started a preset, then fades to at least two more: \(names)")
        #expect(zip(names, names.dropFirst()).allSatisfy { $0 != $1 }, "each fade goes to a different preset")

        var held: [String] = []
        renderer.onPreset = { held.append($0) }
        renderer.select(VisualChoice(visual: .presets, preset: "Tidepool"))
        for _ in 0..<30 {
            _ = renderer.snapshot(width: 320, height: 200, frames: 1)
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(held == ["Tidepool"], "a chosen preset is shown and never fades away: \(held)")
    }

    @Test func aShootingStarCrossesTheStarfield() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), device: device)
        let analyzer = SpectrumAnalyzer()
        playing(analyzer)
        let renderer = try #require(VisualizerRenderer(view: view, analyzer: analyzer))
        renderer.setPalette(DefaultSkin().visColors)
        renderer.pixelDivisor = 2
        renderer.select(.starfield)
        let without = litPixels(try #require(renderer.snapshot(width: 640, height: 400, frames: 5)))
        let with = litPixels(try #require(renderer.snapshot(width: 640, height: 400, frames: 5, shootingStar: 0.5)))
        if let folder = ProcessInfo.processInfo.environment["BITAMP_VISUALIZER_OUT"],
           let image = renderer.snapshot(width: 640, height: 400, frames: 5, shootingStar: 0.5) {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("shooting.png"))
        }
        #expect(with > without, "\(with) lit pixels with a shooting star, \(without) without")
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
        #expect(preferences.fullVisual == VisualChoice(visual: .presets, preset: MilkPresetLibrary.names().last).raw, "stepping back from the first wraps to the last")
    }

    @Test func theVisualizerMenuLabelsTheRetroVisuals() throws {
        let menu = try #require(Menus.visualization().items.first { $0.title == "Visualizer Window" }?.submenu)
        let first = try #require(menu.items.first)
        #expect(first.title == "Retro" && !first.isEnabled, "a greyed-out header over the skin-coloured visuals")
        let titles = menu.items.map(\.title)
        #expect(titles.firstIndex(of: "Bars and Waves") == 1, "the visuals follow the header")
        #expect(titles.firstIndex(of: "Drift") ?? 0 > titles.firstIndex(of: "Alchemy") ?? 99, "Drift comes after them")
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

@Suite struct VisualChoiceTests {
    @Test func choicesRoundTripThroughTheirSavedString() {
        for choice in VisualChoice.all(presetNames: ["Tidepool", "Lattice Rain"]) {
            #expect(VisualChoice(raw: choice.raw) == choice)
        }
        #expect(VisualChoice(raw: "preset:Tidepool") == VisualChoice(visual: .presets, preset: "Tidepool"))
        #expect(VisualChoice(raw: "presets").preset == nil, "Drift has no preset of its own")
        #expect(VisualChoice(raw: "nonsense").visual == .barsAndWaves)
    }

    @Test func menuOrderIsVisualsThenDriftThenEachPreset() {
        let all = VisualChoice.all(presetNames: ["A", "B"])
        #expect(all.map(\.title).suffix(3) == ["Drift", "A", "B"])
        #expect(all.first?.visual == .barsAndWaves)
    }
}
