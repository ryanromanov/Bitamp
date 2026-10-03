import AppKit
import UniformTypeIdentifiers

/// The main window's only view. Composes the skin into a 275×116 bitmap each frame,
/// then scales it up with nearest-neighbor filtering. All hit-testing is in 1× pixels.
final class MainView: NSView {
    static let scale: CGFloat = 2
    static let framesPerSecond = 30.0

    enum VisMode {
        case spectrum, oscilloscope, off
    }

    let engine: PlayerEngine
    var skin: Skin
    var onOpenFiles: (([URL]) -> Void)?
    var onEject: (() -> Void)?

    private let canvas = Canvas(Layout.size)
    private var timer: Timer?
    private var frameCount = 0
    private var marquee = Marquee(visibleWidth: Int(Layout.marquee.width))
    private var visMode = VisMode.spectrum
    private var showRemaining = false
    private var shuffle = false

    // Mouse tracking.
    private var pressed: Control?
    private var pressedInside = false
    private var slider: (control: Control, grab: CGFloat)?
    /// Where the position thumb sits while it's being dragged, 0...1. Seeks on release.
    private var pendingSeek: Double?

    init(engine: PlayerEngine, skin: Skin) {
        self.engine = engine
        self.skin = skin
        super.init(frame: NSRect(origin: .zero, size: NSSize(
            width: Layout.size.width * Self.scale, height: Layout.size.height * Self.scale)))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func flash(_ message: String) {
        marquee.flash(message, for: 3)
    }

    // MARK: - Frame loop

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        frameCount += 1
        marquee.setText(titleText)
        marquee.tick()
        engine.analyzer.advance()
        needsDisplay = true
    }

    private var titleText: String {
        guard let track = engine.track else {
            return "BITAMP - DROP A FILE HERE OR PRESS L TO OPEN ONE"
        }
        let name = [track.artist, track.title].compactMap { $0 }.joined(separator: " - ")
        return "\(name) (\(TimeFormat.clock(track.duration)))"
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(renderFrame(), in: bounds)
    }

    private func renderFrame() -> CGImage {
        let c = canvas
        c.draw(skin.image(for: .mainBackground), 0, 0)
        c.draw(skin.image(for: .titleBar(active: window?.isKeyWindow ?? false)), 0, 0)
        for button in TitleButton.allCases {
            c.draw(skin.image(for: .titleButton(button, pressed: isPressed(.title(button)))), at: button.rect.origin)
        }

        drawTime(c)
        drawVisualizer(c)
        drawMarquee(c)
        drawTrackInfo(c)
        drawSliders(c)

        for button in TransportButton.allCases {
            c.draw(skin.image(for: .transport(button, pressed: isPressed(.transport(button)))), at: button.rect.origin)
        }
        for button in ToggleButton.allCases {
            let image = skin.image(for: .toggle(button, on: isOn(button), pressed: isPressed(.toggle(button))))
            c.draw(image, at: button.rect.origin)
        }
        c.draw(skin.image(for: .about(pressed: isPressed(.about))), at: Layout.about.origin)
        return c.image()
    }

    private func isPressed(_ control: Control) -> Bool {
        pressed == control && pressedInside
    }

    private func isOn(_ button: ToggleButton) -> Bool {
        switch button {
        case .shuffle: return shuffle
        case .repeatTrack: return engine.repeatTrack
        case .equalizer, .playlist: return false
        }
    }

    private func drawTime(_ c: Canvas) {
        let status: PlayStatus
        switch engine.state {
        case .playing: status = .playing
        case .paused: status = .paused
        case .stopped: status = .stopped
        }
        c.draw(skin.image(for: .playStatus(status)), at: Layout.playStatus.origin)

        // Blank while stopped, and blinking while paused.
        let blinkOff = engine.state == .paused && frameCount / 15 % 2 == 1
        guard let track = engine.track, engine.state != .stopped, !blinkOff else {
            for point in Layout.timeDigits {
                c.draw(skin.image(for: .digit(SkinElement.blankDigit)), at: point)
            }
            return
        }
        let elapsed = currentTime(of: track)
        let shown = showRemaining ? max(0, track.duration - elapsed) : elapsed
        if showRemaining {
            c.draw(skin.image(for: .minus), at: Layout.minus.origin)
        }
        for (digit, point) in zip(TimeFormat.lcdDigits(shown), Layout.timeDigits) {
            c.draw(skin.image(for: .digit(digit)), at: point)
        }
    }

    /// The engine's position, or where the user is dragging the position thumb.
    private func currentTime(of track: PlayerEngine.Track) -> Double {
        if let pendingSeek { return pendingSeek * track.duration }
        return engine.currentTime
    }

    private func drawVisualizer(_ c: Canvas) {
        let rect = Layout.visualizer
        let (x0, y0) = (Int(rect.minX), Int(rect.minY))
        let colors = skin.visColors
        c.fill(rect, colors[0])
        guard visMode != .off else { return }
        for y in stride(from: 1, to: Int(rect.height), by: 2) {
            for x in stride(from: 1, to: Int(rect.width), by: 2) {
                c.fill(x0 + x, y0 + y, 1, 1, colors[1])
            }
        }

        let height = Int(rect.height)
        let analyzer = engine.analyzer
        switch visMode {
        case .spectrum:
            for i in 0..<SpectrumAnalyzer.barCount {
                let x = x0 + i * 4
                let bar = Int((analyzer.bars[i] * Float(height)).rounded())
                for row in (height - bar)..<height {
                    c.fill(x, y0 + row, 3, 1, colors[2 + row])
                }
                let peak = Int((analyzer.peaks[i] * Float(height)).rounded())
                if peak > 0 {
                    c.fill(x, y0 + height - peak, 3, 1, colors[23])
                }
            }
        case .oscilloscope:
            let middle = height / 2
            var previous: Int?
            for (x, sample) in analyzer.waveform.enumerated() {
                let y = min(max(middle - Int((sample * Float(middle)).rounded()), 0), height - 1)
                let (low, high) = (min(y, previous ?? y), max(y, previous ?? y))
                for row in low...high {
                    c.fill(x0 + x, y0 + row, 1, 1, colors[18 + min(4, abs(row - middle) / 2)])
                }
                previous = y
            }
        case .off:
            break
        }
    }

    private func drawMarquee(_ c: Canvas) {
        let rect = Layout.marquee
        let (x, y) = (Int(rect.minX), Int(rect.minY))
        c.context.saveGState()
        c.context.clip(to: rect)
        if let overlay = marquee.overlay() {
            drawText(c, overlay, x, y)
        } else if marquee.scrolls {
            let loop = marquee.loop
            let start = x - marquee.offset
            drawText(c, loop, start, y)
            drawText(c, loop, start + PixelFont.width(of: loop), y)
        } else {
            drawText(c, marquee.text, x, y)
        }
        c.context.restoreGState()
    }

    private func drawText(_ c: Canvas, _ text: String, _ x: Int, _ y: Int) {
        let limit = Int(Layout.size.width)
        for (index, character) in PixelFont.normalize(text).enumerated() {
            let glyphX = x + index * PixelFont.cellWidth
            guard glyphX < limit else { break }
            if glyphX > -PixelFont.cellWidth {
                c.draw(skin.glyph(for: character), glyphX, y)
            }
        }
    }

    private func drawTrackInfo(_ c: Canvas) {
        guard let track = engine.track else {
            c.draw(skin.image(for: .mono(active: false)), at: Layout.mono.origin)
            c.draw(skin.image(for: .stereo(active: false)), at: Layout.stereo.origin)
            return
        }
        if let kbps = track.kbps {
            // Three characters at most; 1411 reads "14H" (hundreds).
            let text = kbps < 1000 ? String(kbps) : "\(kbps / 100)H"
            drawRightAligned(c, text, in: Layout.kbps)
        }
        let khz = Int((track.sampleRate / 1000).rounded())
        drawRightAligned(c, String(String(khz).prefix(2)), in: Layout.khz)
        c.draw(skin.image(for: .mono(active: track.channels == 1)), at: Layout.mono.origin)
        c.draw(skin.image(for: .stereo(active: track.channels > 1)), at: Layout.stereo.origin)
    }

    private func drawRightAligned(_ c: Canvas, _ text: String, in rect: CGRect) {
        let width = PixelFont.width(of: text)
        drawText(c, text, Int(rect.maxX) - width, Int(rect.minY))
    }

    private func drawSliders(_ c: Canvas) {
        let lastLevel = Double(SkinElement.sliderLevels - 1)

        let volumeLevel = Int((engine.volume * lastLevel).rounded())
        c.draw(skin.image(for: .volumeBackground(level: volumeLevel)), at: Layout.volume.origin)
        let volumeX = SliderGeometry.volume.thumbX(for: engine.volume)
        c.draw(skin.image(for: .volumeThumb(pressed: slider?.control == .volume)), Int(volumeX), Int(Layout.volume.minY) + 1)

        let balanceLevel = Int((abs(engine.balance) * lastLevel).rounded())
        c.draw(skin.image(for: .balanceBackground(level: balanceLevel)), at: Layout.balance.origin)
        let balanceX = SliderGeometry.balance.thumbX(for: BalanceMapping.slider(fromBalance: engine.balance))
        c.draw(skin.image(for: .balanceThumb(pressed: slider?.control == .balance)), Int(balanceX), Int(Layout.balance.minY) + 1)

        c.draw(skin.image(for: .positionBackground), at: Layout.position.origin)
        if canSeek, let track = engine.track {
            let progress = pendingSeek ?? engine.currentTime / track.duration
            let x = SliderGeometry.position.thumbX(for: progress)
            c.draw(skin.image(for: .positionThumb(pressed: pendingSeek != nil)), Int(x), Int(Layout.position.minY))
        }
    }

    private var canSeek: Bool {
        engine.state != .stopped && (engine.track?.duration ?? 0) > 0
    }

    // MARK: - Mouse

    private func pixel(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: floor(point.x / Self.scale), y: floor((bounds.height - point.y) / Self.scale))
    }

    override func mouseDown(with event: NSEvent) {
        let point = pixel(for: event)
        guard let control = Layout.control(at: point) else {
            window?.performDrag(with: event)
            return
        }
        switch control {
        case .volume, .balance, .position:
            beginSliderDrag(control, at: point)
        case .timeDisplay:
            showRemaining.toggle()
        case .visualizer:
            switch visMode {
            case .spectrum: visMode = .oscilloscope
            case .oscilloscope: visMode = .off
            case .off: visMode = .spectrum
            }
        default:
            pressed = control
            pressedInside = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = pixel(for: event)
        if slider != nil {
            updateSlider(at: point)
        } else if let pressed {
            pressedInside = pressed.rect.contains(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let slider {
            if slider.control == .position, let pendingSeek, let track = engine.track {
                engine.seek(to: pendingSeek * track.duration)
            }
            self.slider = nil
            pendingSeek = nil
            marquee.message = nil
        } else if let pressed {
            if pressedInside { perform(pressed) }
            self.pressed = nil
            pressedInside = false
        }
        needsDisplay = true
    }

    private func geometry(for control: Control) -> SliderGeometry {
        switch control {
        case .volume: return .volume
        case .balance: return .balance
        default: return .position
        }
    }

    private func sliderValue(for control: Control) -> Double {
        switch control {
        case .volume: return engine.volume
        case .balance: return BalanceMapping.slider(fromBalance: engine.balance)
        default:
            guard let track = engine.track, track.duration > 0 else { return 0 }
            return engine.currentTime / track.duration
        }
    }

    private func beginSliderDrag(_ control: Control, at point: CGPoint) {
        if control == .position && !canSeek { return }
        let geometry = geometry(for: control)
        let thumbX = geometry.thumbX(for: sliderValue(for: control))
        // Grab the thumb where it was clicked; a click on the track centers the thumb there.
        let grab = (thumbX..<thumbX + geometry.thumbWidth).contains(point.x)
            ? point.x - thumbX
            : (geometry.thumbWidth / 2).rounded(.down)
        slider = (control, grab)
        updateSlider(at: point)
    }

    private func updateSlider(at point: CGPoint) {
        guard let slider else { return }
        let value = geometry(for: slider.control).value(forThumbX: point.x - slider.grab)
        switch slider.control {
        case .volume:
            engine.volume = value
            marquee.message = volumeMessage
        case .balance:
            engine.balance = BalanceMapping.balance(fromSlider: value)
            let balance = engine.balance
            marquee.message = balance == 0
                ? "BALANCE: CENTER"
                : "BALANCE: \(Int((abs(balance) * 100).rounded()))% \(balance < 0 ? "LEFT" : "RIGHT")"
        default:
            guard let track = engine.track else { return }
            pendingSeek = value
            marquee.message = "SEEK TO: \(TimeFormat.clock(value * track.duration))/"
                + "\(TimeFormat.clock(track.duration)) (\(Int((value * 100).rounded()))%)"
        }
    }

    private var volumeMessage: String {
        "VOLUME: \(Int((engine.volume * 100).rounded()))%"
    }

    private func perform(_ control: Control) {
        switch control {
        case .title(.close): NSApp.terminate(nil)
        case .title(.minimize): window?.miniaturize(nil)
        case .transport(.previous), .transport(.next): engine.restart()
        case .transport(.play): play()
        case .transport(.pause): engine.pause()
        case .transport(.stop): engine.stop()
        case .transport(.eject): onEject?()
        case .toggle(.shuffle): shuffle.toggle()
        case .toggle(.repeatTrack): engine.repeatTrack.toggle()
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        default: break  // Options, shade, EQ and playlist arrive in later phases.
        }
    }

    private func play() {
        if engine.track == nil {
            onEject?()
        } else {
            engine.play()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z", "b": engine.restart()
        case "x": play()
        case "c": engine.pause()
        case "v": engine.stop()
        case "l": onEject?()
        default:
            switch event.specialKey {
            case .leftArrow?: engine.seek(to: engine.currentTime - 5)
            case .rightArrow?: engine.seek(to: engine.currentTime + 5)
            case .upArrow?: nudgeVolume(by: 0.02)
            case .downArrow?: nudgeVolume(by: -0.02)
            default: super.keyDown(with: event)
            }
        }
    }

    private func nudgeVolume(by amount: Double) {
        engine.volume = min(max(engine.volume + amount, 0), 1)
        marquee.flash(volumeMessage, for: 1)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        audioURLs(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = audioURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onOpenFiles?(urls)
        return true
    }

    private func audioURLs(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) ?? false }
    }
}
