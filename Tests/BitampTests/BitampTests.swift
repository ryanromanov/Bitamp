import AppKit
import AVFoundation
import ImageIO
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
        #expect(volume.thumbStart(for: 0) == Layout.volume.minX)
        #expect(volume.thumbStart(for: 1) == Layout.volume.maxX - Layout.sliderThumb.width)
        #expect(volume.thumbStart(for: 2) == volume.thumbStart(for: 1))
    }

    @Test func roundTrip() {
        let position = SliderGeometry.position
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            let back = position.value(forThumbStart: position.thumbStart(for: value))
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
    @Test func sizesSnapToTheThreeOnOffer() throws {
        let suite = "BitampTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.scale == 2)
        // 3× and 4× were offered before; they become 2×.
        for (saved, expected): (Double, CGFloat) in [(4, 2), (3, 2), (1, 1), (1.5, 1.5), (1.2, 1), (0, 1)] {
            defaults.set(saved, forKey: "scale")
            #expect(preferences.scale == expected)
        }
        // Older versions stored a whole number.
        defaults.set(1, forKey: "scale")
        #expect(preferences.scale == 1)
        preferences.scale = 1.5
        #expect(Preferences(defaults: defaults).scale == 1.5)
    }

    @Test func copiesSettingsFromTheOldBundleIDOnce() throws {
        let suite = "BitampTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(0.2, forKey: "volume")
        OldSettings.copy(["volume": 0.9, "skin": "Orb"], into: defaults)
        #expect(defaults.double(forKey: "volume") == 0.2)
        #expect(defaults.string(forKey: "skin") == "Orb")

        defaults.removeObject(forKey: "skin")
        OldSettings.copyIfNeeded(into: defaults)
        #expect(defaults.string(forKey: "skin") == nil)
    }

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

@Suite struct DockingTests {
    let main = CGRect(x: 100, y: 500, width: 550, height: 232)

    @Test func snapsBelowAndAligned() {
        // 6 points below and 4 to the right of a flush stack under the main window.
        let near = CGRect(x: 104, y: 500 - 232 - 6, width: 550, height: 232)
        #expect(Docking.snap(near, to: [main]) == CGPoint(x: 100, y: 500 - 232))
    }

    @Test func leavesFarWindowsAlone() {
        let far = CGRect(x: 400, y: 100, width: 550, height: 232)
        #expect(Docking.snap(far, to: [main]) == far.origin)
    }

    @Test func snapsToScreenEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let nearCorner = CGRect(x: 7, y: 895 - 232, width: 550, height: 232)
        #expect(Docking.snap(nearCorner, to: [], within: screen) == CGPoint(x: 0, y: 900 - 232))
    }

    @Test func dockedFollowsChains() {
        let equalizer = CGRect(x: 100, y: 268, width: 550, height: 232)    // under main
        let playlist = CGRect(x: 100, y: 36, width: 550, height: 232)      // under the equalizer
        let loose = CGRect(x: 900, y: 500, width: 550, height: 232)
        let sideways = CGRect(x: 650, y: 600, width: 550, height: 232)     // right of main
        #expect(Docking.docked(to: main, among: [playlist, loose, equalizer, sideways]) == [0, 2, 3])
    }

    @Test func cornersDoNotDock() {
        let diagonal = CGRect(x: 650, y: 268, width: 550, height: 232)
        #expect(!Docking.touching(main, diagonal))
    }
}

@Suite struct QueueEditingTests {
    let urls = (0..<6).map { URL(fileURLWithPath: "/music/\($0).mp3") }

    func queue(at index: Int = 0) -> PlayQueue {
        var queue = PlayQueue(seed: 9)
        queue.replace(with: urls)
        queue.select(index)
        return queue
    }

    @Test func removingOthersKeepsCurrent() {
        var q = queue(at: 3)
        q.remove([0, 5])
        #expect(q.items == [urls[1], urls[2], urls[3], urls[4]])
        #expect(q.current == urls[3])
        #expect(q.playingIndex == 2)
    }

    @Test func removingCurrentPlaysWhatFollowedNext() {
        var q = queue(at: 2)
        q.remove([2])
        #expect(q.playingIndex == nil)
        #expect(q.next() == urls[3])  // Not urls[4]: nothing is skipped.
        #expect(q.playingIndex == 2)
    }

    @Test func removingCurrentAtTheEnd() {
        var q = queue(at: 5)
        q.remove([5])
        #expect(q.next() == nil)
    }

    @Test func movingABlock() {
        var q = queue(at: 0)
        let moved = q.move([1, 2], by: 2)
        #expect(moved == [3, 4])
        #expect(q.items == [urls[0], urls[3], urls[4], urls[1], urls[2], urls[5]])
        #expect(q.current == urls[0])
    }

    @Test func movingStopsAtTheEnds() {
        var q = queue()
        #expect(q.move([4, 5], by: 3) == [4, 5])
        #expect(q.move([0], by: -1) == [0])
        #expect(q.items == urls)
    }

    @Test func insertKeepsCurrent() {
        var q = queue(at: 1)
        let extra = [URL(fileURLWithPath: "/music/new.mp3")]
        q.insert(extra, at: 0)
        #expect(q.items.first == extra[0])
        #expect(q.current == urls[1])
        #expect(q.next() == urls[2])
    }

    @Test func sortReverseAndRandomize() {
        var q = queue(at: 4)
        q.reverse()
        #expect(q.items == urls.reversed())
        #expect(q.current == urls[4])
        q.sort { $0.lastPathComponent }
        #expect(q.items == urls)
        q.randomize()
        #expect(Set(q.items) == Set(urls))
        #expect(q.current == urls[4])
    }

    @Test func shuffledEditsKeepPlayOrder() {
        var q = PlayQueue(seed: 5)
        q.setShuffled(true)
        q.replace(with: urls)
        let upcoming = q.order.dropFirst().map { q.items[$0] }
        q.reverse()
        #expect(q.order.dropFirst().map { q.items[$0] } == upcoming)
    }

    @Test func removeAll() {
        var q = queue(at: 2)
        q.removeAll()
        #expect(q.isEmpty)
        #expect(q.current == nil)
        #expect(q.next() == nil)
    }
}

@Suite struct M3UTests {
    @Test func readsTitlesAndDurationsBack() {
        let text = """
        #EXTM3U
        #EXTINF:61,X - One
        /a/One.mp3
        #EXTINF:-1,Two
        /a/Two.mp3
        /a/Three.mp3
        #EXTINF:200,Moby - Heroes, Reprise
        radio://station/i.RBWoDFZzENpE
        """
        let entries = M3U.parseEntries(text, relativeTo: URL(fileURLWithPath: "/"), schemes: ["radio"])
        #expect(entries.map(\.title) == ["X - One", "Two", nil, "Moby - Heroes, Reprise"])
        #expect(entries.map(\.duration) == [61, nil, nil, 200])
        #expect(entries[3].url.absoluteString == "radio://station/i.RBWoDFZzENpE")
    }

    @Test func parsesAbsoluteRelativeAndWindowsPaths() {
        let base = URL(fileURLWithPath: "/Users/me/Music/Lists")
        let text = """
        #EXTM3U
        #EXTINF:215,Artist - Song
        /Volumes/Disk/song.mp3

        ../Album/02 Two.flac\r
        Album\\03 Three.m4a
        file:///tmp/four.wav
        http://example.com/stream
        """
        let urls = M3U.parse(text, relativeTo: base).map(\.path)
        #expect(urls == [
            "/Volumes/Disk/song.mp3",
            "/Users/me/Music/Album/02 Two.flac",
            "/Users/me/Music/Lists/Album/03 Three.m4a",
            "/tmp/four.wav",
        ])
    }

    @Test func writesExtendedM3U() {
        let text = M3U.write([
            M3U.Entry(url: URL(fileURLWithPath: "/a/One.mp3"), title: "X - One", duration: 61.4),
            M3U.Entry(url: URL(fileURLWithPath: "/a/Two.mp3"), title: nil, duration: nil),
        ])
        #expect(text == "#EXTM3U\n#EXTINF:61,X - One\n/a/One.mp3\n#EXTINF:-1,Two\n/a/Two.mp3\n")
    }

    @Test func roundTripsThroughExpand() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let songs = ["b.mp3", "a.m4a"].map { folder.appendingPathComponent($0) }
        songs.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
        let list = folder.appendingPathComponent("list.m3u8")
        let missing = folder.appendingPathComponent("gone.mp3")
        try M3U.write((songs + [missing]).map { M3U.Entry(url: $0) }).write(to: list, atomically: true, encoding: .utf8)
        // Playlist order is kept, and missing files are dropped.
        #expect(AudioFiles.expand([list]).map(\.lastPathComponent) == ["b.mp3", "a.m4a"])
    }
}

@Suite struct EqualizerTests {
    let geometry = VerticalSliderGeometry(track: EQLayout.band(0), thumbHeight: EQLayout.thumb.height)

    @Test func sliderEnds() {
        #expect(geometry.thumbY(for: 12) == EQLayout.band(0).minY)
        #expect(geometry.thumbY(for: -12) == EQLayout.band(0).maxY - EQLayout.thumb.height)
        #expect(geometry.decibels(forThumbY: EQLayout.band(0).minY) == 12)
        #expect(geometry.decibels(forThumbY: EQLayout.band(0).maxY) == -12)
    }

    @Test func middleSnapsToFlat() {
        #expect(geometry.decibels(forThumbY: geometry.thumbY(for: 0)) == 0)
        #expect(geometry.decibels(forThumbY: geometry.thumbY(for: 0.4)) == 0)
    }

    @Test func curvePassesThroughBands() {
        let bands: [Float] = [6, 3, 0, -3, -6, 0, 6, 12, 0, -12]
        let curve = EqualizerView.curve(bands, width: 10)
        for (a, b) in zip(curve, bands) { #expect(abs(a - b) < 0.001) }
        #expect(EqualizerView.curve(bands, width: 113).allSatisfy { EqualizerSettings.range.contains($0) })
    }

    @Test func settingsClampAndPresetsAreValid() {
        let wild = EqualizerSettings(enabled: true, preamp: 40, bands: [20, -20])
        #expect(wild.clamped.preamp == 12)
        #expect(wild.clamped.bands == [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
        for preset in EqualizerPreset.builtIn {
            #expect(preset.bands.count == 10, "\(preset.name)")
            #expect(preset.apply(to: .flat) == EqualizerSettings(enabled: true, preamp: preset.preamp, bands: preset.bands))
        }
        #expect(Set(EqualizerPreset.builtIn.map(\.name)).count == EqualizerPreset.builtIn.count)
    }

    @Test func controlsHitTestAndDoNotOverlap() {
        let all = EQLayout.Control.all
        for control in all {
            #expect(EQLayout.control(at: CGPoint(x: control.rect.midX, y: control.rect.midY)) == control)
        }
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a) overlaps \(b)") }
        }
    }
}

@Suite struct PlaylistLayoutTests {
    @Test func heightSnapsToTileSteps() {
        #expect(PlaylistLayout.snappedHeight(50) == 116)
        #expect(PlaylistLayout.snappedHeight(130) == 116)
        #expect(PlaylistLayout.snappedHeight(131) == 145)
        #expect(PlaylistLayout.snappedHeight(232) == 232)
    }

    @Test(arguments: [116.0, 232, 406])
    func controlsAtAnyHeight(height: Double) {
        let size = CGSize(width: PlaylistLayout.width, height: height)
        for button in PlaylistLayout.Button.allCases {
            let rect = PlaylistLayout.rect(button, in: size)
            #expect(PlaylistLayout.control(at: CGPoint(x: rect.midX, y: rect.midY), in: size) == .button(button))
        }
        for button in TransportButton.allCases {
            let rect = PlaylistLayout.rect(button, in: size)
            #expect(PlaylistLayout.control(at: CGPoint(x: rect.midX, y: rect.midY), in: size) == .transport(button))
        }
        let list = PlaylistLayout.list(in: size)
        #expect(PlaylistLayout.control(at: CGPoint(x: list.midX, y: list.midY), in: size) == .list)
        #expect(PlaylistLayout.control(at: CGPoint(x: 268, y: 5), in: size) == .close)
        #expect(PlaylistLayout.control(at: CGPoint(x: 100, y: 10), in: size) == .titleBar)
        #expect(PlaylistLayout.control(at: CGPoint(x: 270, y: height - 3), in: size) == .resizeGrip)
    }

    @Test func newSpriteSizes() {
        let skin = DefaultSkin()
        func size(_ element: SkinElement) -> CGSize {
            let image = skin.image(for: element)
            return CGSize(width: image.width, height: image.height)
        }
        #expect(size(.eqBackground) == EQLayout.size)
        #expect(size(.eqSliderBackground(level: 0)) == EQLayout.preamp.size)
        #expect(size(.eqGraphBackground) == EQLayout.graph.size)
        for button in [EQButton.on, .auto, .presets] {
            #expect(size(.eqButton(button, on: true, pressed: false)) == EQLayout.button(button).size)
        }
        #expect(size(.playlistBottomLeft).width + size(.playlistBottomRight).width == PlaylistLayout.width)
        #expect(size(.playlistLeftTile) == CGSize(width: PlaylistLayout.left, height: PlaylistLayout.heightStep))
        #expect(size(.playlistRightTile) == CGSize(width: PlaylistLayout.right, height: PlaylistLayout.heightStep))
        #expect(skin.eqGraphColors.count == 19)
    }
}

@Suite struct SkinLoadingTests {
    /// A solid-color bitmap encoded as BMP.
    func bmp(width: Int, height: Int, color: UInt32) throws -> Data {
        let canvas = Canvas(width, height)
        canvas.fill(0, 0, width, height, rgb(color))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.microsoft.bmp" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, canvas.image(), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Zips `files` with the system zip tool (deflated, in a subfolder like many skins).
    func makeSkin(_ files: [String: Data]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = folder.appendingPathComponent("MySkin")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: inner.appendingPathComponent(name)) }
        let zip = folder.appendingPathComponent("MySkin.wsz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-qr", zip.path, "MySkin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }

    @Test func zipReaderInflatesEntries() throws {
        let text = String(repeating: "Bitamp skins are zips of bitmaps. ", count: 200)
        let url = try makeSkin(["notes.txt": Data(text.utf8)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try ZipArchive(url: url)
        let entry = try #require(archive.entries.first { $0.path.hasSuffix("notes.txt") })
        #expect(entry.method == 8)  // Deflated, so this exercises decompression.
        #expect(try archive.contents(of: entry) == Data(text.utf8))
    }

    @Test func rejectsNonZips() {
        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive(data: Data("not a zip".utf8)) }
    }

    @Test func cutsSpritesAndFallsBack() throws {
        let url = try makeSkin([
            "MAIN.BMP": try bmp(width: 275, height: 116, color: 0x112233),  // Upper case, as some skins have.
            "cbuttons.bmp": try bmp(width: 136, height: 36, color: 0x445566),
            "viscolor.txt": Data((0..<24).map { "\($0),\($0),\($0), // color \($0)" }.joined(separator: "\r\n").utf8),
            "pledit.txt": Data("[Text]\nNormal=#00FF00\nCurrent=#FFFFFF\nNormalBG=#000000\nSelectedBG=#0000C6\nFont=Arial\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fallback = DefaultSkin()
        let skin = try WszSkin(url: url, fallback: fallback)
        #expect(skin.name == "MySkin")

        let background = skin.image(for: .mainBackground)
        #expect(background.width == 275 && background.height == 116)
        let play = skin.image(for: .transport(.play, pressed: true))
        #expect(play.width == 23 && play.height == 18)
        // No posbar.bmp: the default skin's sprite stands in.
        #expect(skin.image(for: .positionBackground) === fallback.image(for: .positionBackground))

        #expect(skin.visColors.count == 24)
        #expect(skin.visColors[5].components?.prefix(3).map { ($0 * 255).rounded() } == [5, 5, 5])
        #expect(skin.playlistColors.selectedBackground.components?.prefix(3).map { ($0 * 255).rounded() } == [0, 0, 198])
    }

    @Test func readsGenFrameAndMeasuresItsLetters() throws {
        // A gen.bmp whose letters are 3, 4, 5, 3, 4, 5… wide, each followed by a column of
        // the row's background color, as Winamp lays them out.
        let c = Canvas(194, 109)
        c.fill(0, 0, 194, 109, rgb(0x808080))
        for y in [88, 96] {
            c.fill(0, y, 194, 7, rgb(0x00c6ff))
            var x = 1
            for index in 0..<26 {
                c.fill(x, y, 3 + index % 3, 7, rgb(0xffffff))
                x += 3 + index % 3 + 1
            }
        }
        let png = try #require(NSBitmapImageRep(cgImage: c.image()).representation(using: .png, properties: [:]))
        let skin = try WszSkin(name: "Gen", files: ["gen.png": png])
        let gen = try #require(skin.gen)
        #expect(gen.letter("A", active: true)?.width == 3)
        #expect(gen.letter("B", active: false)?.width == 4)
        #expect(gen.letter("Z", active: true)?.width == 4)
        #expect(gen.letter(" ", active: true) == nil)
        #expect(gen.titleWidth("AB C") == 3 + 4 + GenArt.spaceWidth + 5)

        // Too small to hold the frame: no gen art, so windows keep their fallback frame.
        let small = try #require(NSBitmapImageRep(cgImage: Canvas(100, 50).image()).representation(using: .png, properties: [:]))
        #expect(try WszSkin(name: "Small", files: ["gen.png": small]).gen == nil)
        #expect(try WszSkin(name: "None", files: ["main.png": small]).gen == nil)
    }

    /// A run-length encoded bitmap: `compression` 1 is RLE8, 2 is RLE4.
    func rleBitmap(width: Int, height: Int, bitsPerPixel: Int, compression: Int, palette: [UInt32], pixels: [UInt8]) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16 & 0xFFFF) }
        let offset = 14 + 40 + palette.count * 4
        var bytes: [UInt8] = [0x42, 0x4D] + u32(offset + pixels.count) + u32(0) + u32(offset)
        bytes += u32(40) + u32(width) + u32(height) + u16(1) + u16(bitsPerPixel) + u32(compression)
        bytes += u32(pixels.count) + u32(2835) + u32(2835) + u32(palette.count) + u32(0)
        for color in palette {
            bytes += [UInt8(color & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color >> 16 & 0xFF), 0]
        }
        return Data(bytes + pixels)
    }

    /// Each pixel as 0xRRGGBB, top row first.
    func colors(_ image: CGImage) -> [UInt32] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) << 16 | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2])
        }
    }

    @Test func decodesRLE8IncludingDeltasThatSkipRows() throws {
        // Bottom-up rows: a run; three literal pixels (padded to an even length) and a run;
        // then a delta that skips the third row entirely and lands two pixels into the
        // fourth, the case ImageIO decodes into the wrong rows. Skipped pixels take color 0.
        let pixels: [UInt8] = [
            4, 1, 0, 0,
            0, 3, 2, 3, 2, 0, 1, 3, 0, 0,
            0, 2, 2, 1, 2, 2, 0, 1,
        ]
        let palette: [UInt32] = [0x00C6FF, 0x111111, 0x222222, 0x333333]
        let data = rleBitmap(width: 4, height: 4, bitsPerPixel: 8, compression: 1, palette: palette, pixels: pixels)
        let image = try #require(RLEBitmap.decode(data))
        let (o, a, b, c) = (palette[0], palette[1], palette[2], palette[3])
        #expect(colors(image) == [o, o, b, b,  o, o, o, o,  b, c, b, c,  a, a, a, a])
    }

    @Test func decodesRLE4() throws {
        // A run of alternating nibbles, then three literal nibbles packed into two bytes.
        let pixels: [UInt8] = [3, 0x12, 0, 3, 0x30, 0x10, 0, 1]
        let palette: [UInt32] = [0x000000, 0x111111, 0x222222, 0x333333]
        let data = rleBitmap(width: 6, height: 1, bitsPerPixel: 4, compression: 2, palette: palette, pixels: pixels)
        let image = try #require(RLEBitmap.decode(data))
        #expect(colors(image) == [1, 2, 1, 3, 0, 1].map { palette[$0] })
    }

    @Test func leavesUncompressedBitmapsToImageIO() throws {
        #expect(RLEBitmap.decode(try bmp(width: 4, height: 4, color: 0x123456)) == nil)
        #expect(RLEBitmap.decode(Data("not a bitmap".utf8)) == nil)
    }

    @Test func spriteMapStaysInsideClassicSheets() {
        // The classic sheet sizes; every mapped sprite must fit inside its sheet.
        let sheets: [String: CGSize] = [
            "main": CGSize(width: 275, height: 116), "titlebar": CGSize(width: 344, height: 87),
            "cbuttons": CGSize(width: 136, height: 36), "playpaus": CGSize(width: 42, height: 9),
            "monoster": CGSize(width: 56, height: 24), "volume": CGSize(width: 68, height: 433),
            "balance": CGSize(width: 47, height: 433), "posbar": CGSize(width: 307, height: 10),
            "shufrep": CGSize(width: 92, height: 85), "eqmain": CGSize(width: 275, height: 315),
            "pledit": CGSize(width: 280, height: 186), "eq_ex": CGSize(width: 275, height: 56),
        ]
        var elements: [SkinElement] = [.mainBackground, .positionBackground, .eqBackground, .eqGraphBackground,
                                       .eqPreampLine, .playlistLeftTile, .playlistRightTile, .playlistBottomLeft,
                                       .playlistBottomRight, .playlistBottomTile]
        for flag in [false, true] {
            elements += [.titleBar(active: flag), .mono(active: flag), .stereo(active: flag),
                         .volumeThumb(pressed: flag), .balanceThumb(pressed: flag), .positionThumb(pressed: flag),
                         .eqTitleBar(active: flag), .eqSliderThumb(pressed: flag), .playlistTopLeft(active: flag),
                         .playlistTitle(active: flag), .playlistTopTile(active: flag), .playlistTopRight(active: flag),
                         .playlistScrollThumb(pressed: flag)]
            elements += TitleButton.allCases.map { .titleButton($0, pressed: flag) }
            elements += TransportButton.allCases.map { .transport($0, pressed: flag) }
            for on in [false, true] {
                elements += ToggleButton.allCases.map { .toggle($0, on: on, pressed: flag) }
                elements += [EQButton.on, .auto, .presets].map { .eqButton($0, on: on, pressed: flag) }
            }
        }
        elements += [.mainShadePosition, .playlistShadeTile, .eqShadeButton(pressed: true),
                     .eqUnshadeButton(pressed: true), .eqShadeCloseButton(pressed: true),
                     .playlistShadeButton(pressed: true), .playlistUnshadeButton(pressed: true)]
        for flag in [false, true] {
            elements += [.mainShadeBackground(active: flag), .mainUnshadeButton(pressed: flag),
                         .eqShadeBackground(active: flag), .playlistShadeLeft(active: flag),
                         .playlistShadeRight(active: flag)]
        }
        for thumb in [ShadeThumb.left, .center, .right] {
            elements += [.mainShadeThumb(thumb), .eqShadeVolumeThumb(thumb), .eqShadeBalanceThumb(thumb)]
        }
                elements += (0..<SkinElement.sliderLevels).flatMap {
            [.volumeBackground(level: $0), .balanceBackground(level: $0), .eqSliderBackground(level: $0)]
        }
        for element in elements {
            guard let (sheet, rect) = WszSkin.source(for: element) else {
                Issue.record("No sprite for \(element)")
                continue
            }
            let size = sheets[sheet]!
            #expect(rect.maxX <= size.width && rect.maxY <= size.height, "\(element) is outside \(sheet).bmp")
        }
    }

    @Test func textMapCoversTheFont() {
        for character in PixelFont.glyphs.keys {
            #expect(WszSkin.textPosition(character) != nil, "No text.bmp cell for \(character)")
        }
    }
}

@Suite struct ShadeTests {
    @Test func mainShadeControls() {
        let strip = CGRect(x: 0, y: 0, width: 275, height: ShadeLayout.height)
        for button in TransportButton.allCases {
            let rect = ShadeLayout.mainTransport(button)
            #expect(strip.contains(rect))
            #expect(ShadeLayout.mainControl(at: CGPoint(x: rect.midX, y: rect.midY)) == .transport(button))
        }
        for (a, b) in zip(TransportButton.allCases, TransportButton.allCases.dropFirst()) {
            #expect(!ShadeLayout.mainTransport(a).intersects(ShadeLayout.mainTransport(b)))
        }
        #expect(ShadeLayout.mainControl(at: CGPoint(x: 258, y: 7)) == .title(.shade))
        #expect(ShadeLayout.mainControl(at: CGPoint(x: 230, y: 7)) == .position)
        #expect(ShadeLayout.mainControl(at: CGPoint(x: 90, y: 7)) == .visualizer)
        #expect(ShadeLayout.mainControl(at: CGPoint(x: 140, y: 7)) == .timeDisplay)
        #expect(ShadeLayout.mainControl(at: CGPoint(x: 40, y: 7)) == nil)  // Drag area.
    }

    @Test func thumbLooks() {
        #expect(ShadeThumb(0) == .left)
        #expect(ShadeThumb(0.5) == .center)
        #expect(ShadeThumb(1) == .right)
    }

    @Test func playlistShadeButtonsSitInTheRightCorner() {
        let width = PlaylistLayout.width
        #expect(!ShadeLayout.playlistUnshade(width: width).intersects(ShadeLayout.playlistClose(width: width)))
        #expect(!ShadeLayout.playlistShadeButton(width: width).intersects(PlaylistLayout.close(in: CGSize(width: width, height: 232))))
        #expect(ShadeLayout.playlistClose(width: width).maxX <= width)
        #expect(ShadeLayout.playlistTitle(width: width).maxX <= ShadeLayout.playlistTime(width: width).x)
    }

    @Test func defaultShadeSpritesHaveTheRightSizes() {
        let skin = DefaultSkin()
        func size(_ element: SkinElement) -> CGSize {
            let image = skin.image(for: element)
            return CGSize(width: image.width, height: image.height)
        }
        #expect(size(.mainShadeBackground(active: true)) == CGSize(width: 275, height: 14))
        #expect(size(.eqShadeBackground(active: false)) == CGSize(width: 275, height: 14))
        #expect(size(.playlistShadeLeft(active: true)) == CGSize(width: 25, height: 14))
        #expect(size(.playlistShadeRight(active: true)) == CGSize(width: 50, height: 14))
        #expect(size(.mainShadeThumb(.center)) == ShadeLayout.thumb)
        #expect(size(.mainShadePosition) == ShadeLayout.mainPosition.size)
    }
}

@Suite struct ListFontTests {
    @Test func glyphsAreWellFormed() {
        for (character, rows) in ListFont.glyphs {
            #expect((1...9).contains(rows.count), "\(character) has \(rows.count) rows")
            #expect(Set(rows.map(\.count)).count == 1, "\(character) has uneven rows")
            #expect(rows.allSatisfy { $0.allSatisfy { $0 == "." || $0 == "#" } }, "\(character)")
            #expect(rows.joined().contains("#"), "\(character) is blank")
        }
    }

    @Test func coversPrintableASCII() {
        for value in 32...126 {
            let character = Character(UnicodeScalar(UInt8(value)))
            #expect(ListFont.glyph(for: character) != nil, "Missing \(character)")
        }
    }

    @Test func buildsAccentedLetters() {
        for character in "éèêëàáâäãåçñöøüÉÖÅÇÑíì" {
            #expect(ListFont.glyph(for: character) != nil, "Missing \(character)")
        }
        guard case .glyph(_, let accent)? = ListFont.glyph(for: "ö") else {
            Issue.record("ö isn't a glyph")
            return
        }
        #expect(accent == .diaeresis)
    }

    @Test func fallsBackForOtherScripts() {
        #expect(ListFont.pieces("坂本 - Merry") == [.fallback("坂本")] + ListFont.pieces(" - Merry"))
        #expect(ListFont.width(of: "坂本") > 0)
    }

    @Test func measuresAndTruncates() {
        #expect(ListFont.width(of: "") == 0)
        #expect(ListFont.width(of: "A") == 5)
        #expect(ListFont.width(of: "AA") == 11)  // Two glyphs and a 1-pixel gap.
        #expect(ListFont.width(of: "il") == 4)
        let long = "The Avalanches - Since I Left You"
        let cut = ListFont.truncate(long, toWidth: 60)
        #expect(cut.hasSuffix("..."))
        #expect(ListFont.width(of: cut) <= 60)
        #expect(ListFont.truncate("Short", toWidth: 200) == "Short")
    }

    @Test func plainsTypographicPunctuation() {
        #expect(ListFont.substitute("It’s “Here” – now…") == "It's \"Here\" - now...")
    }

    @Test func rowsFitTheFont() {
        #expect(PlaylistLayout.rowHeight == CGFloat(ListFont.lineHeight))
        // Descenders end on the last row of the line.
        #expect(ListFont.accentRows + 9 == ListFont.lineHeight)
    }
}

@Suite struct ThemeAndExportTests {
    /// RGBA bytes of an image, for exact comparisons.
    func bytes(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    func rgbBytes(_ color: CGColor) -> [Int] {
        (color.components ?? []).prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test(arguments: [SkinTheme.classic, .millennium].map(\.name))
    func everyThemeDrawsEverySpriteAtItsSize(name: String) {
        let theme = name == SkinTheme.millennium.name ? SkinTheme.millennium : .classic
        let skin = DefaultSkin(theme: theme)
        for element in WszWriter.elements {
            guard let (_, rect) = WszSkin.source(for: element) else { continue }
            let image = skin.image(for: element)
            #expect(image.width == Int(rect.width) && image.height == Int(rect.height), "\(element) in \(name)")
        }
        #expect(skin.visColors.count == 24)
        #expect(skin.eqGraphColors.count == 19)
    }

    @Test func exportedSkinLoadsBackIdentically() throws {
        let skin = DefaultSkin(theme: .millennium)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Millennium-\(UUID().uuidString).wsz")
        defer { try? FileManager.default.removeItem(at: url) }
        try WszWriter.write(skin, to: url)

        // Load it with a fallback that would show up as a mismatch if it were ever used.
        let loaded = try WszSkin(url: url, fallback: DefaultSkin(theme: .classic))
        var mismatches: [String] = []
        for element in WszWriter.elements + (0...SkinElement.blankDigit).map(SkinElement.digit) + [.minus] {
            if bytes(loaded.image(for: element)) != bytes(WszWriter.flattened(element, from: skin)) {
                mismatches.append("\(element)")
            }
        }
        // Two classic-format limits: in titlebar.bmp the active and inactive shade strips share
        // a row (y 29 + 14 overlaps y 42), and pledit.bmp has only one shaded-playlist left
        // piece, so the inactive one comes back as the active one.
        #expect(Set(mismatches) == ["mainShadeBackground(active: false)", "playlistShadeLeft(active: false)"],
                "Sprites that changed in the round trip: \(mismatches)")
        let inactiveStrip = bytes(loaded.image(for: .mainShadeBackground(active: false)))
        let expectedStrip = bytes(WszWriter.flattened(.mainShadeBackground(active: false), from: skin))
        let rowBytes = 275 * 4
        #expect(inactiveStrip[rowBytes...] == expectedStrip[rowBytes...], "Only the shared top row should differ")
        #expect(bytes(loaded.image(for: .playlistShadeLeft(active: false)))
                == bytes(WszWriter.flattened(.playlistShadeLeft(active: true), from: skin)))

        #expect(loaded.visColors.map(rgbBytes) == skin.visColors.map(rgbBytes))
        #expect(loaded.eqGraphColors.map(rgbBytes) == skin.eqGraphColors.map(rgbBytes))
        #expect(rgbBytes(loaded.playlistColors.normal) == rgbBytes(skin.playlistColors.normal))
        #expect(rgbBytes(loaded.playlistColors.selectedBackground) == rgbBytes(skin.playlistColors.selectedBackground))
    }

    @Test func exportedFilesAreTheClassicSet() {
        let names = Set(WszWriter.files(for: DefaultSkin()).keys)
        #expect(names == Set(WszWriter.sheetSizes.keys.map { "\($0).bmp" } + ["viscolor.txt", "pledit.txt"]))
    }
}

@Suite struct BuiltInSkinTests {
    @Test func savedNamesMapToBuiltIns() {
        #expect(SkinTheme.builtIn(named: nil)?.id == "default")  // Nothing saved yet.
        #expect(SkinTheme.builtIn(named: "builtin:millennium")?.id == "millennium")
        #expect(SkinTheme.builtIn(named: "builtin:default")?.id == "default")
        #expect(SkinTheme.builtIn(named: "TopazAmp1-2") == nil)  // An installed .wsz.
        #expect(SkinTheme.builtIn(named: "builtin:nope") == nil)
        #expect(Set(SkinTheme.builtIn.map(\.id)).count == SkinTheme.builtIn.count)
    }
}

@Suite struct OrbTests {
    @Test func verticalSliderRunsBottomToTop() {
        let volume = SliderGeometry(track: OrbLayout.volume, thumbWidth: OrbLayout.volumeThumb.height, vertical: true)
        #expect(volume.thumbStart(for: 1) == OrbLayout.volume.minY)
        #expect(volume.thumbStart(for: 0) == OrbLayout.volume.maxY - OrbLayout.volumeThumb.height)
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            let back = volume.value(forThumbStart: volume.thumbStart(for: value))
            #expect(abs(back - value) <= 1 / Double(volume.travel))
        }
        #expect(volume.along(CGPoint(x: 3, y: 40)) == 40)
    }

    @Test func roundButtonsHitAsCircles() {
        let play = OrbLayout.orbCenter
        #expect(OrbLayout.control(at: play) == .transport(.play))
        // The corner of the play button's square is outside its circle, on the ring.
        let corner = OrbLayout.rect(of: .play).origin
        #expect(OrbLayout.control(at: CGPoint(x: corner.x + 1, y: corner.y + 1)) == nil)
        for button in TransportButton.allCases {
            #expect(OrbLayout.control(at: OrbLayout.center(of: button)) == .transport(button))
        }
        for button in OrbLayout.toggles {
            let rect = OrbLayout.rect(of: button)
            #expect(OrbLayout.control(at: CGPoint(x: rect.midX, y: rect.midY)) == .toggle(button))
        }
        for button in TitleButton.allCases {
            let rect = OrbLayout.titleButton(button)
            #expect(OrbLayout.control(at: CGPoint(x: rect.midX, y: rect.midY)) == .title(button))
        }
    }

    @Test func everyControlIsOnTheShape() {
        for control in [Control.volume, .position, .timeDisplay, .visualizer]
            + TitleButton.allCases.map(Control.title) + TransportButton.allCases.map(Control.transport)
            + OrbLayout.toggles.map(Control.toggle) {
            let rect = OrbLayout.rect(of: control)
            #expect(OrbLayout.contains(CGPoint(x: rect.midX, y: rect.midY)), "\(control)")
        }
        // The corners of the bounding box are transparent.
        #expect(!OrbLayout.contains(.zero))
        #expect(!OrbLayout.contains(CGPoint(x: OrbLayout.size.width - 1, y: OrbLayout.size.height - 1)))
    }

    /// The alpha of a pixel, top-left origin.
    func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    @Test func artMatchesTheShape() {
        let image = OrbArt(theme: .orb).background(active: true)
        #expect(CGSize(width: image.width, height: image.height) == OrbLayout.size)
        for (x, y) in [(0, 0), (317, 115), (150, 112), (300, 2)] {
            #expect(alpha(image, x, y) == 0, "(\(x), \(y)) should be clear")
            #expect(!OrbLayout.contains(CGPoint(x: x, y: y)))
        }
        for (x, y) in [(58, 58), (200, 60), (200, 10), (200, 105)] {
            #expect(alpha(image, x, y) == 255, "(\(x), \(y)) should be opaque")
            #expect(OrbLayout.contains(CGPoint(x: x, y: y)))
        }
    }

    @MainActor @Test func switchingSkinsResizesTheMainWindow() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampOrb-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        #expect(view.pixelSize == Layout.size)
        view.skin = DefaultSkin(theme: .orb)
        #expect(view.pixelSize == OrbLayout.size)
        #expect(view.frame.size == NSSize(width: OrbLayout.size.width * view.scale, height: OrbLayout.size.height * view.scale))
        #expect(view.isShapedWindow)
        view.skin = DefaultSkin(theme: .millennium)
        #expect(view.pixelSize == Layout.size)
        #expect(!view.isShapedWindow)
    }

    /// Draws `view` as a Retina screen would and counts screen pixels that differ from the
    /// top-left screen pixel of their skin pixel. Past the art, on a half-point edge, they
    /// should match the edge.
    @MainActor func unevenPixels(_ view: NSView) -> Int {
        guard let skinned = view as? SkinnedView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                         pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let data = rep.bitmapData else { return -1 }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let step = Int(skinned.scale * 2)
        let artWidth = skinned.canvas.width * step, artHeight = skinned.canvas.height * step
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            data.advanced(by: y * rep.bytesPerRow + x * 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        }
        var uneven = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let sourceX = min(x, artWidth - 1) / step * step, sourceY = min(y, artHeight - 1) / step * step
                if pixel(x, y) != pixel(sourceX, sourceY) { uneven += 1 }
            }
        }
        return uneven
    }

    /// 1.5× keeps the windows docked, and the layout comes back at 1.5× after a relaunch.
    @MainActor @Test func oneAndAHalfTimesKeepsTheLayout() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "BitampScale-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        func windows() -> (SkinnedWindow, SkinnedWindow, SkinnedWindow, WindowGroup) {
            let main = SkinnedWindow(view: MainView(controller: controller, preferences: preferences, skin: DefaultSkin()),
                                     layoutName: "MainWindow", isMain: true)
            let equalizer = SkinnedWindow(view: EqualizerView(controller: controller, skin: DefaultSkin(), scale: preferences.scale),
                                          layoutName: "EqualizerWindow", isMain: false)
            let playlist = SkinnedWindow(view: PlaylistView(controller: controller, preferences: preferences, skin: DefaultSkin()),
                                         layoutName: "PlaylistWindow", isMain: false)
            let group = WindowGroup(main: main, panels: [.equalizer: equalizer, .playlist: playlist], defaults: defaults)
            group.restore()
            return (main, equalizer, playlist, group)
        }

        let (main, equalizer, playlist, group) = windows()
        defer { for window in [main, equalizer, playlist] { window.orderOut(nil) } }
        group.regroup()
        preferences.scale = 1.5
        group.setScale(1.5)
        // AppKit rounds windows to whole points: 412.5 becomes 413.
        #expect(abs(main.frame.width - Layout.size.width * 1.5) <= 0.5 && main.frame.height == Layout.size.height * 1.5)
        // Every skin pixel is 3 × 3 screen pixels on a Retina display, including in a
        // playlist whose height is an odd number of pixels.
        #expect(unevenPixels(main.contentView!) == 0)
        playlist.setContentSize(NSSize(width: PlaylistLayout.width * 1.5, height: (PlaylistLayout.minHeight + PlaylistLayout.heightStep) * 1.5))
        #expect(playlist.contentView!.bounds.height == 218)
        #expect(unevenPixels(playlist.contentView!) == 0)
        #expect(equalizer.frame.maxY == main.frame.minY && playlist.frame.maxY == equalizer.frame.minY)
        #expect(equalizer.frame.minX == main.frame.minX && playlist.frame.minX == main.frame.minX)
        group.saveLayout()

        let (main2, equalizer2, playlist2, _) = windows()
        defer { for window in [main2, equalizer2, playlist2] { window.orderOut(nil) } }
        #expect(main2.frame == main.frame && equalizer2.frame == equalizer.frame && playlist2.frame == playlist.frame)
    }

    /// The main window hides and shows like Winamp's (Alt+W), something always stays on
    /// screen, the choice survives a relaunch, and commands still reach the main view.
    @MainActor @Test func mainWindowCanHide() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "BitampMainWindow-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        let mainView = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        let playlist = SkinnedWindow(view: PlaylistView(controller: controller, preferences: preferences, skin: DefaultSkin()),
                                     layoutName: "PlaylistWindow", isMain: false)
        let equalizer = SkinnedWindow(view: EqualizerView(controller: controller, skin: DefaultSkin(), scale: 1),
                                      layoutName: "EqualizerWindow", isMain: false)
        playlist.actionFallback = mainView
        let main = SkinnedWindow(view: mainView, layoutName: "MainWindow", isMain: true)
        func group() -> WindowGroup {
            WindowGroup(main: main, panels: [.playlist: playlist, .equalizer: equalizer], defaults: defaults)
        }
        defer { for window in [main, playlist, equalizer] { window.orderOut(nil) } }

        let first = group()
        first.restore()
        first.showAtLaunch()
        #expect(first.isMainVisible && first.isVisible(.playlist) && first.isVisible(.equalizer))
        first.toggleMain()
        #expect(!first.isMainVisible && first.isVisible(.playlist))

        // Hidden at quit, hidden at the next launch.
        main.orderOut(nil); playlist.orderOut(nil); equalizer.orderOut(nil)
        let second = group()
        second.restore()
        second.showAtLaunch()
        #expect(!second.isMainVisible && second.isVisible(.playlist))

        // Closing the last other window brings the main window back.
        second.setVisible(.equalizer, false)
        #expect(!second.isMainVisible)
        second.setVisible(.playlist, false)
        #expect(second.isMainVisible)
        // And with nothing else showing, it won't hide.
        #expect(!second.canHideMain)
        second.setMainVisible(false)
        #expect(second.isMainVisible)

        // Hidden, the main window goes with the windows docked to it: move them, close them,
        // and it comes back where it was against the playlist.
        second.setVisible(.playlist, true)
        second.setVisible(.equalizer, true)
        let before = (main: main.frame.origin, playlist: playlist.frame.origin)
        second.setMainVisible(false)
        for window in [playlist, equalizer] {
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 120, y: window.frame.minY - 80))
        }
        second.setVisible(.playlist, false)
        second.setVisible(.equalizer, false)
        #expect(second.isMainVisible)
        #expect(main.frame.minX - playlist.frame.minX == before.main.x - before.playlist.x)
        #expect(main.frame.minY - playlist.frame.minY == before.main.y - before.playlist.y)

        // Regrouping stacks the equalizer and then the playlist under the main window.
        func expectStacked() {
            #expect(equalizer.frame.minX == main.frame.minX && equalizer.frame.maxY == main.frame.minY)
            #expect(playlist.frame.minX == main.frame.minX && playlist.frame.maxY == equalizer.frame.minY)
        }
        second.setVisible(.playlist, true)
        second.setVisible(.equalizer, true)
        playlist.setFrameOrigin(NSPoint(x: playlist.frame.minX + 300, y: playlist.frame.minY + 40))
        equalizer.setFrameOrigin(NSPoint(x: equalizer.frame.minX - 200, y: equalizer.frame.minY - 90))
        second.regroup()
        expectStacked()
        // Hidden, the windows stack from the top one, and the main window comes back above them.
        second.setMainVisible(false)
        playlist.setFrameOrigin(NSPoint(x: playlist.frame.minX + 150, y: playlist.frame.minY + 500))
        let playlistTop = NSPoint(x: playlist.frame.minX, y: playlist.frame.maxY)
        second.regroup()
        #expect(equalizer.frame.minX == playlistTop.x && equalizer.frame.maxY == playlistTop.y)
        second.setMainVisible(true)
        expectStacked()

        // The playlist hands playback commands to the main view.
        #expect(playlist.supplementalTarget(forAction: #selector(MainView.play(_:)), sender: nil) as? MainView === mainView)
    }

    /// Plain letters are shortcuts; with Option, Control or Command held they aren't.
    @MainActor @Test func letterShortcutsIgnoreModifiedKeys() throws {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "BitampKeys-\(UUID().uuidString)")!)
        let controller = PlaybackController(engine: PlayerEngine(), preferences: preferences)
        let view = MainView(controller: controller, preferences: preferences, skin: DefaultSkin())
        func press(_ modifiers: NSEvent.ModifierFlags) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)))
        }
        let repeats = controller.repeats
        try press([])
        #expect(controller.repeats == !repeats)
        try press([.shift])
        #expect(controller.repeats == repeats)
        for modifiers: NSEvent.ModifierFlags in [.option, .control, .command] {
            try press(modifiers)
            #expect(controller.repeats == repeats, "\(modifiers)")
        }
    }

    @Test func onlyTheOrbThemeHasOrbArt() {
        #expect(DefaultSkin(theme: .orb).orb != nil)
        #expect(DefaultSkin(theme: .millennium).orb == nil)
        #expect(DefaultSkin().orb == nil)
        #expect(SkinTheme.builtIn(named: "builtin:orb")?.mainShape == .orb)
    }
}
