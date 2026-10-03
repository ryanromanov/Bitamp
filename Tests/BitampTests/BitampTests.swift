import AVFoundation
import Foundation
import Testing
@testable import BitampKit

@Suite struct TimeFormatTests {
    @Test func clock() {
        #expect(TimeFormat.clock(0) == "0:00")
        #expect(TimeFormat.clock(65.9) == "1:05")
        #expect(TimeFormat.clock(600) == "10:00")
        #expect(TimeFormat.clock(3725) == "1:02:05")
        #expect(TimeFormat.clock(-3) == "0:00")
    }

    @Test func lcdDigits() {
        #expect(TimeFormat.lcdDigits(0) == [0, 0, 0, 0])
        #expect(TimeFormat.lcdDigits(754) == [1, 2, 3, 4])
        #expect(TimeFormat.lcdDigits(99 * 60 + 59) == [9, 9, 5, 9])
        // Past 99:59 the display switches to hours and minutes.
        #expect(TimeFormat.lcdDigits(100 * 60) == [0, 1, 4, 0])
    }
}

@Suite struct LayoutTests {
    @Test func controlsFitTheWindow() {
        let window = CGRect(origin: .zero, size: Layout.size)
        for control in Control.all {
            #expect(window.contains(control.rect), "\(control) is outside the window")
        }
    }

    @Test func controlsDoNotOverlap() {
        let all = Control.all
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                #expect(!a.rect.intersects(b.rect), "\(a) overlaps \(b)")
            }
        }
    }

    @Test func hitTesting() {
        for control in Control.all {
            #expect(Layout.control(at: CGPoint(x: control.rect.midX, y: control.rect.midY)) == control)
        }
        #expect(Layout.control(at: CGPoint(x: 150, y: 7)) == nil)  // Title bar, for dragging.
        #expect(Layout.control(at: CGPoint(x: 264, y: 3)) == .title(.close))
        #expect(Layout.control(at: CGPoint(x: 273, y: 3)) == nil)
    }
}

@Suite struct SliderTests {
    @Test func thumbTravel() {
        let volume = SliderGeometry.volume
        #expect(volume.thumbX(for: 0) == Layout.volume.minX)
        #expect(volume.thumbX(for: 1) == Layout.volume.maxX - Layout.sliderThumb.width)
        #expect(volume.thumbX(for: 2) == volume.thumbX(for: 1))
    }

    @Test func roundTrip() {
        let position = SliderGeometry.position
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            let back = position.value(forThumbX: position.thumbX(for: value))
            #expect(abs(back - value) <= 1 / Double(position.travel))
        }
    }

    @Test func balanceSnapsToCenter() {
        #expect(BalanceMapping.balance(fromSlider: 0.52) == 0)
        #expect(BalanceMapping.balance(fromSlider: 0) == -1)
        #expect(BalanceMapping.balance(fromSlider: 1) == 1)
        #expect(BalanceMapping.slider(fromBalance: 0) == 0.5)
    }
}

@Suite struct SpectrumTests {
    @Test(arguments: [22_050.0, 44_100, 48_000, 96_000])
    func bandsAreContiguousAndNonEmpty(sampleRate: Double) {
        let bands = SpectrumAnalyzer.bandBins(sampleRate: sampleRate)
        #expect(bands.count == SpectrumAnalyzer.barCount)
        #expect(bands.first!.lowerBound >= 1)
        #expect(bands.last!.upperBound <= SpectrumAnalyzer.fftSize / 2)
        for band in bands { #expect(!band.isEmpty) }
        for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    }

    @Test func sineLightsTheMatchingBar() throws {
        let sampleRate = 44_100.0
        let frequency = 1_000.0
        let frames = AVAudioFrameCount(SpectrumAnalyzer.fftSize)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
            }
        }

        let analyzer = SpectrumAnalyzer()
        analyzer.sampleRate = sampleRate
        analyzer.process(buffer)
        analyzer.advance()

        let bin = Int((frequency / (sampleRate / Double(SpectrumAnalyzer.fftSize))).rounded())
        let expected = try #require(SpectrumAnalyzer.bandBins(sampleRate: sampleRate).firstIndex { $0.contains(bin) })
        let loudest = analyzer.bars.indices.max { analyzer.bars[$0] < analyzer.bars[$1] }
        #expect(loudest == expected)
        #expect(analyzer.bars[expected] > 0.9)
        #expect(analyzer.bars[0] < 0.5)
    }

    @Test func fullScaleSineIsZeroDecibels() {
        // A full-scale sine through a Hann window peaks at N/2 in vDSP_fft_zrip's output.
        let n = Float(SpectrumAnalyzer.fftSize)
        let power = (n / 2) * (n / 2)
        #expect(SpectrumAnalyzer.level(power: power) == 1)
        #expect(SpectrumAnalyzer.level(power: 0) == 0)
    }

    @Test func barsFallWithoutData() {
        let analyzer = SpectrumAnalyzer()
        analyzer.advance()
        #expect(analyzer.bars.allSatisfy { $0 == 0 })
    }
}

@Suite struct MarqueeTests {
    @Test func shortTextStaysPut() {
        var marquee = Marquee(visibleWidth: 154)
        marquee.setText("Short")
        marquee.tick()
        #expect(!marquee.scrolls)
        #expect(marquee.offset == 0)
    }

    @Test func longTextLoops() {
        var marquee = Marquee(visibleWidth: 20)
        marquee.setText("Long enough to scroll")
        let loopWidth = PixelFont.width(of: marquee.loop)
        for _ in 0..<loopWidth { marquee.tick() }
        #expect(marquee.offset == 0)
        marquee.tick()
        #expect(marquee.offset == 1)
    }

    @Test func newTextRestartsScroll() {
        var marquee = Marquee(visibleWidth: 20)
        marquee.setText("Long enough to scroll")
        marquee.tick()
        marquee.setText("Another long title here")
        #expect(marquee.offset == 0)
    }

    @Test func flashExpires() {
        var marquee = Marquee(visibleWidth: 154)
        let now = Date()
        marquee.flash("Hello", for: 1, now: now)
        #expect(marquee.overlay(at: now) == "HELLO")
        #expect(marquee.overlay(at: now.addingTimeInterval(2)) == nil)
        marquee.message = "Volume: 50%"
        #expect(marquee.overlay(at: now) == "Volume: 50%")
    }
}

@Suite struct FontAndSkinTests {
    @Test func glyphsAreFourByFive() {
        for (character, rows) in PixelFont.glyphs {
            #expect(rows.count == 5, "\(character)")
            for row in rows {
                #expect(row.count == 4 && row.allSatisfy { $0 == "." || $0 == "#" }, "\(character)")
            }
        }
    }

    @Test func normalize() {
        #expect(PixelFont.normalize("Café – Ñandú") == "CAFE - NANDU")
        #expect(PixelFont.normalize("日本") == "??")
    }

    @Test func spriteSizesMatchLayout() {
        let skin = DefaultSkin()
        func size(_ element: SkinElement) -> CGSize {
            let image = skin.image(for: element)
            return CGSize(width: image.width, height: image.height)
        }
        #expect(size(.mainBackground) == Layout.size)
        #expect(size(.titleBar(active: true)) == Layout.titleBar.size)
        for button in TransportButton.allCases {
            #expect(size(.transport(button, pressed: false)) == button.rect.size)
        }
        for button in ToggleButton.allCases {
            #expect(size(.toggle(button, on: true, pressed: true)) == button.rect.size)
        }
        for button in TitleButton.allCases {
            #expect(size(.titleButton(button, pressed: false)) == button.rect.size)
        }
        #expect(size(.volumeBackground(level: 27)) == Layout.volume.size)
        #expect(size(.balanceBackground(level: 0)) == Layout.balance.size)
        #expect(size(.positionBackground) == Layout.position.size)
        #expect(size(.positionThumb(pressed: false)) == Layout.positionThumb)
        #expect(size(.digit(8)) == CGSize(width: 9, height: 13))
        #expect(skin.visColors.count == 24)
    }
}
