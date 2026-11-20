import AppKit
import Testing
@testable import BitampKit

/// A skinned view in a window shows its picture by giving its layer the canvas. If the layer
/// stays empty the window is see-through, with only its subviews showing.
@MainActor @Suite struct LayerPresentationTests {
    /// What AppKit does for a view on screen: it asks for a backing layer, then calls `updateLayer`.
    /// (There's no display to do it in a test, so it's done here.)
    private func updated(_ view: SkinnedView) {
        view.wantsLayer = true
        #expect(view.wantsUpdateLayer)
        view.updateLayer()
    }

    @Test func aViewInAWindowFillsItsLayerWithItsPicture() {
        let controller = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: UserDefaults(suiteName: "BitampLayer-\(UUID().uuidString)")!))
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 2)
        updated(view)
        let contents = view.layer?.contents
        #expect(contents != nil, "the layer has no picture")
        if let image = contents as! CGImage? {
            #expect(image.width == Int(view.pixelSize.width) && image.height == Int(view.pixelSize.height))
        }
        #expect(view.layer?.magnificationFilter == .nearest)
    }

    @Test func anOddSizeAtOneAndAHalfKeepsTheArtExactAndFillsTheEdge() {
        let controller = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: UserDefaults(suiteName: "BitampLayer-\(UUID().uuidString)")!))
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1.5)
        // One point wider than the art, as AppKit's whole-point window sizes can leave.
        view.setFrameSize(NSSize(width: view.naturalSize.width.rounded(.up) + 1, height: view.naturalSize.height.rounded(.up) + 1))
        updated(view)
        #expect(view.layer?.contents != nil)
        let art = view.layer?.sublayers?.first
        #expect(art?.contents != nil, "the art sits in its own layer when the view is bigger than the art")
        if let art {
            #expect(abs(art.frame.width - view.naturalSize.width) < 0.01)
        }
    }

    @Test func aViewNotInAWindowStillDrawsForScreenshots() throws {
        let controller = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: UserDefaults(suiteName: "BitampLayer-\(UUID().uuidString)")!))
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Not a blank bitmap: the skin's art has more than one colour.
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        #expect(colours.count > 5, "\(colours.count) colours")
    }

    @Test func aFrameThatComesOutTheSameIsNotShownAgain() {
        let controller = PlaybackController(engine: PlayerEngine(), preferences: Preferences(defaults: UserDefaults(suiteName: "BitampLayer-\(UUID().uuidString)")!))
        let view = EqualizerView(controller: controller, skin: DefaultSkin(), scale: 2)
        view.wantsLayer = true
        view.updateLayer()
        #expect(view.presentedFrames == 1 && view.skippedFrames == 0)
        // Nothing changed: drawn again, but not given to the layer again.
        view.updateLayer()
        view.updateLayer()
        #expect(view.presentedFrames == 1 && view.skippedFrames == 2)

        // Something on the window changes: the next frame is shown.
        var settings = controller.equalizer
        settings.preamp = 9
        controller.equalizer = settings
        view.updateLayer()
        #expect(view.presentedFrames == 2)
        view.updateLayer()
        #expect(view.presentedFrames == 2 && view.skippedFrames == 3)

        // The window is resized or the scale changes: shown again even if the art is the same.
        view.setFrameSize(NSSize(width: view.frame.width + 3, height: view.frame.height + 3))
        view.updateLayer()
        #expect(view.presentedFrames == 3)

        // If the layer loses its picture, it's put back.
        view.layer?.contents = nil
        view.updateLayer()
        #expect(view.presentedFrames == 4 && view.layer?.contents != nil)
    }
}
