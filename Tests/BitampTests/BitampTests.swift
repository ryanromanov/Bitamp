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

@Suite struct PlayQueueTests {
    let urls = (1...5).map { URL(fileURLWithPath: "/music/\($0).mp3") }

    @Test func playsInOrderAndStopsAtTheEnd() {
        var queue = PlayQueue(seed: 1)
        queue.replace(with: urls)
        var played = [queue.current!]
        while let next = queue.next() { played.append(next) }
        #expect(played == urls)
        #expect(queue.current == urls.last)  // Stays on the last track.
    }

    @Test func previousStopsAtTheStart() {
        var queue = PlayQueue(seed: 1)
        queue.replace(with: urls)
        #expect(queue.previous() == urls[0])
    }

    @Test func repeatWrapsBothWays() {
        var queue = PlayQueue(seed: 1)
        queue.replace(with: urls)
        queue.repeats = true
        #expect(queue.previous() == urls[4])
        #expect(queue.next() == urls[0])
    }

    @Test func shufflePlaysEveryTrackOnce() {
        var queue = PlayQueue(seed: 42)
        queue.setShuffled(true)
        queue.replace(with: urls)
        var played = [queue.current!]
        while let next = queue.next() { played.append(next) }
        #expect(Set(played) == Set(urls))
        #expect(played.count == urls.count)
    }

    @Test func turningShuffleOnKeepsTheCurrentTrack() {
        var queue = PlayQueue(seed: 7)
        queue.replace(with: urls)
        queue.next()
        queue.next()
        queue.setShuffled(true)
        #expect(queue.current == urls[2])
        queue.setShuffled(false)
        #expect(queue.current == urls[2])
        #expect(queue.next() == urls[3])
    }

    @Test func shuffledRepeatDoesNotRepeatATrackBackToBack() {
        for seed in 0..<50 as Range<UInt64> {
            var queue = PlayQueue(seed: seed)
            queue.setShuffled(true)
            queue.repeats = true
            queue.replace(with: urls)
            for _ in 0..<4 { queue.next() }
            let last = queue.current
            #expect(queue.next() != last)
        }
    }

    @Test func appendKeepsTheCurrentTrack() {
        var queue = PlayQueue(seed: 3)
        queue.replace(with: Array(urls[..<2]))
        queue.next()
        queue.append(Array(urls[2...]))
        #expect(queue.current == urls[1])
        #expect(queue.next() == urls[2])

        var shuffled = PlayQueue(seed: 3)
        shuffled.setShuffled(true)
        shuffled.replace(with: Array(urls[..<2]))
        let current = shuffled.current
        shuffled.append(Array(urls[2...]))
        #expect(shuffled.current == current)
        #expect(Set(shuffled.order) == Set(0..<5))
    }

    @Test func emptyQueue() {
        var queue = PlayQueue()
        #expect(queue.current == nil)
        #expect(queue.next() == nil)
        #expect(queue.previous() == nil)
    }
}

@Suite struct AudioFilesTests {
    @Test func expandsFoldersInNameOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let album = root.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["10 Ten.mp3", "2 Two.m4a", "1 One.flac", "cover.jpg", ".hidden.mp3", "list.m3u"] {
            FileManager.default.createFile(atPath: album.appendingPathComponent(name).path, contents: Data())
        }
        let loose = root.appendingPathComponent("loose.wav")
        FileManager.default.createFile(atPath: loose.path, contents: Data())

        let names = AudioFiles.expand([loose, album, root.appendingPathComponent("missing.mp3")])
            .map(\.lastPathComponent)
        #expect(names == ["loose.wav", "1 One.flac", "2 Two.m4a", "10 Ten.mp3"])
    }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func defaultsAndRoundTrip() throws {
        let suite = "BitampTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.volume == 0.75)
        #expect(preferences.visMode == .spectrum)
        #expect(preferences.showPeaks)
        #expect(preferences.barFalloff == .normal)

        preferences.visMode = .oscilloscope
        preferences.oscilloscopeStyle = .solid
        preferences.volume = 0.3
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.visMode == .oscilloscope)
        #expect(reloaded.oscilloscopeStyle == .solid)
        #expect(reloaded.volume == 0.3)
    }

    @Test func falloffSpeedsAreOrdered() {
        #expect(Falloff.slow.barRate < Falloff.normal.barRate)
        #expect(Falloff.normal.barRate < Falloff.fast.barRate)
        #expect(Falloff.slow.peakRate < Falloff.fast.peakRate)
    }
}

@Suite struct VisualizerTuningTests {
    /// A 2048-frame stereo buffer of a 1 kHz sine at `amplitude`.
    func sine(_ amplitude: Float) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(SpectrumAnalyzer.fftSize)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = amplitude * Float(sin(2 * .pi * 1_000 * Double(i) / 44_100))
            }
        }
        return buffer
    }

    @Test func quietAudioFillsTheScope() throws {
        let analyzer = SpectrumAnalyzer()
        analyzer.process(try sine(0.2))
        analyzer.advance()
        let peak = analyzer.waveform.map(abs).max()!
        #expect(peak > 0.8 && peak <= 1)
    }

    @Test func silenceIsNotAmplifiedIntoNoise() {
        let analyzer = SpectrumAnalyzer()
        analyzer.advance()
        #expect(analyzer.waveform.allSatisfy { $0 == 0 })
    }

    @Test(arguments: Falloff.allCases)
    func barsFallAtTheChosenRate(falloff: Falloff) throws {
        let analyzer = SpectrumAnalyzer()
        analyzer.barFall = falloff.barRate
        analyzer.process(try sine(1))
        analyzer.advance()
        let loudest = analyzer.bars.indices.max { analyzer.bars[$0] < analyzer.bars[$1] }!
        let start = analyzer.bars[loudest]

        analyzer.process(try sine(0))
        for _ in 0..<5 { analyzer.advance() }
        let expected = max(0, start - 5 * falloff.barRate)
        #expect(abs(analyzer.bars[loudest] - expected) < 0.001)
    }

    @Test func speedsAreFarApart() {
        #expect(Falloff.fast.barRate / Falloff.slow.barRate >= 10)
        #expect(Falloff.fast.peakRate / Falloff.slow.peakRate >= 10)
        #expect(Falloff.slow.peakHoldFrames > Falloff.fast.peakHoldFrames)
    }
}
