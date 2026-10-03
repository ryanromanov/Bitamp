import AppKit

/// The main window: transport, time, visualizer and marquee.
///
/// It's also the first responder for the Playback and Visualization menus, from any
/// Bitamp window, because the other windows never become main.
final class MainView: SkinnedView, NSMenuItemValidation {
    let controller: PlaybackController
    let preferences: Preferences
    /// Shows the open panel.
    var onOpen: (() -> Void)?

    private var engine: PlayerEngine { controller.engine }
    private var marquee = Marquee(visibleWidth: Int(Layout.marquee.width))

    // Mouse tracking.
    private var pressed: Control?
    private var pressedInside = false
    private var slider: (control: Control, grab: CGFloat)?
    /// Where the position thumb sits while it's being dragged, 0...1. Seeks on release.
    private var pendingSeek: Double?
    /// Audio files in the drag over the window, keyed by pasteboard change count.
    private var dropFileCount: (changeCount: Int, count: Int)?

    init(controller: PlaybackController, preferences: Preferences, skin: Skin) {
        self.controller = controller
        self.preferences = preferences
        super.init(pixelSize: Layout.size, skin: skin)
        registerForDraggedTypes([.fileURL])
        applyFalloff()
        announce = { [weak self] message in self?.marquee.message = message }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func flash(_ message: String, for seconds: TimeInterval = 3) {
        marquee.flash(message, for: seconds)
    }

    // MARK: - Frame loop

    override func tick() {
        marquee.setText(titleText)
        marquee.tick()
        engine.analyzer.advance()
    }

    private var titleText: String {
        guard let track = engine.track else {
            return "BITAMP - DROP FILES OR FOLDERS HERE, OR PRESS L TO OPEN"
        }
        let name = [track.artist, track.title].compactMap { $0 }.joined(separator: " - ")
        let number = controller.queue.currentIndex.map { "\($0 + 1). " } ?? ""
        return "\(number)\(name) (\(TimeFormat.clock(track.duration)))"
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        c.draw(skin.image(for: .mainBackground), 0, 0)
        c.draw(skin.image(for: .titleBar(active: isActive)), 0, 0)
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
    }

    private func isPressed(_ control: Control) -> Bool {
        pressed == control && pressedInside
    }

    private func isOn(_ button: ToggleButton) -> Bool {
        switch button {
        case .shuffle: return controller.shuffle
        case .repeatTrack: return controller.repeats
        case .equalizer: return windowGroup?.isVisible(.equalizer) ?? false
        case .playlist: return windowGroup?.isVisible(.playlist) ?? false
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
        let showRemaining = preferences.showRemaining
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
        let mode = preferences.visMode
        guard mode != .off else { return }
        for y in stride(from: 1, to: Int(rect.height), by: 2) {
            for x in stride(from: 1, to: Int(rect.width), by: 2) {
                c.fill(x0 + x, y0 + y, 1, 1, colors[1])
            }
        }

        let height = Int(rect.height)
        let analyzer = engine.analyzer
        switch mode {
        case .spectrum:
            let showPeaks = preferences.showPeaks
            for i in 0..<SpectrumAnalyzer.barCount {
                let x = x0 + i * 4
                let bar = Int((analyzer.bars[i] * Float(height)).rounded())
                for row in (height - bar)..<height {
                    c.fill(x, y0 + row, 3, 1, colors[2 + row])
                }
                let peak = Int((analyzer.peaks[i] * Float(height)).rounded())
                if showPeaks && peak > 0 {
                    c.fill(x, y0 + height - peak, 3, 1, colors[23])
                }
            }
        case .oscilloscope:
            let middle = height / 2
            let style = preferences.oscilloscopeStyle
            var previous: Int?
            for (x, sample) in analyzer.waveform.enumerated() {
                // Dots skip every other column; packed tighter they'd read as a line.
                if style == .dots && x % 2 == 1 { continue }
                let y = min(max(middle - Int((sample * Float(middle)).rounded()), 0), height - 1)
                let rows: ClosedRange<Int>
                switch style {
                case .dots: rows = y...y
                case .lines: rows = min(y, previous ?? y)...max(y, previous ?? y)
                case .solid: rows = min(y, middle)...max(y, middle)
                }
                for row in rows {
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
            drawPixelText(c, overlay, x, y)
        } else if marquee.scrolls {
            let loop = marquee.loop
            let start = x - marquee.offset
            drawPixelText(c, loop, start, y)
            drawPixelText(c, loop, start + PixelFont.width(of: loop), y)
        } else {
            drawPixelText(c, marquee.text, x, y)
        }
        c.context.restoreGState()
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
        drawPixelText(c, text, Int(rect.maxX) - width, Int(rect.minY))
    }

    private func drawSliders(_ c: Canvas) {
        let lastLevel = Double(SkinElement.sliderLevels - 1)

        let volumeLevel = Int((controller.volume * lastLevel).rounded())
        c.draw(skin.image(for: .volumeBackground(level: volumeLevel)), at: Layout.volume.origin)
        let volumeX = SliderGeometry.volume.thumbX(for: controller.volume)
        c.draw(skin.image(for: .volumeThumb(pressed: slider?.control == .volume)), Int(volumeX), Int(Layout.volume.minY) + 1)

        let balanceLevel = Int((abs(controller.balance) * lastLevel).rounded())
        c.draw(skin.image(for: .balanceBackground(level: balanceLevel)), at: Layout.balance.origin)
        let balanceX = SliderGeometry.balance.thumbX(for: BalanceMapping.slider(fromBalance: controller.balance))
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

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let control = Layout.control(at: point) else { return false }
        switch control {
        case .volume, .balance, .position:
            beginSliderDrag(control, at: point)
        case .timeDisplay:
            preferences.showRemaining.toggle()
        case .visualizer:
            let modes = VisMode.allCases
            preferences.visMode = modes[(modes.firstIndex(of: preferences.visMode)! + 1) % modes.count]
        default:
            pressed = control
            pressedInside = true
        }
        return true
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        if slider != nil {
            updateSlider(at: point)
        } else if let pressed {
            pressedInside = pressed.rect.contains(point)
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
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
    }

    /// Right-clicking the visualizer shows its options; anywhere else, the main menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        Layout.control(at: pixel(for: event)) == .visualizer ? Menus.visualization() : Menus.context()
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
        nudgeVolume(by: Double(event.scrollingDeltaY) * step)
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
        case .volume: return controller.volume
        case .balance: return BalanceMapping.slider(fromBalance: controller.balance)
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
            controller.volume = value
            marquee.message = volumeMessage
        case .balance:
            controller.balance = BalanceMapping.balance(fromSlider: value)
            let balance = controller.balance
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
        "VOLUME: \(Int((controller.volume * 100).rounded()))%"
    }

    private func nudgeVolume(by amount: Double) {
        guard amount != 0 else { return }
        controller.volume += amount
        marquee.flash(volumeMessage, for: 1)
    }

    private func perform(_ control: Control) {
        switch control {
        case .title(.options):
            let button = TitleButton.options.rect
            let below = NSPoint(x: button.minX * Self.scale, y: bounds.height - button.maxY * Self.scale)
            Menus.context().popUp(positioning: nil, at: below, in: self)
        case .title(.close): NSApp.terminate(nil)
        case .title(.minimize): window?.miniaturize(nil)
        case .transport(.previous): previousTrack(nil)
        case .transport(.play): play(nil)
        case .transport(.pause): pause(nil)
        case .transport(.stop): stop(nil)
        case .transport(.next): nextTrack(nil)
        case .transport(.eject): openFiles(nil)
        case .toggle(.shuffle): toggleShuffle(nil)
        case .toggle(.repeatTrack): toggleRepeat(nil)
        case .toggle(.equalizer): windowGroup?.toggle(.equalizer)
        case .toggle(.playlist): windowGroup?.toggle(.playlist)
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        default: break  // Shade mode arrives in Phase 4.
        }
    }

    // MARK: - Menu actions

    @objc func openFiles(_ sender: Any?) { onOpen?() }
    @objc func previousTrack(_ sender: Any?) { controller.previous() }
    @objc func nextTrack(_ sender: Any?) { controller.next() }
    @objc func pause(_ sender: Any?) { engine.pause() }
    @objc func stop(_ sender: Any?) { engine.stop() }

    @objc func play(_ sender: Any?) {
        if controller.queue.isEmpty {
            onOpen?()
        } else {
            controller.play()
        }
    }

    @objc func toggleShuffle(_ sender: Any?) {
        controller.shuffle.toggle()
        marquee.flash("SHUFFLE: \(controller.shuffle ? "ON" : "OFF")", for: 1)
    }

    @objc func toggleRepeat(_ sender: Any?) {
        controller.repeats.toggle()
        marquee.flash("REPEAT: \(controller.repeats ? "ON" : "OFF")", for: 1)
    }

    @objc func setVisMode(_ sender: NSMenuItem) {
        guard let mode = choice(VisMode.self, sender) else { return }
        preferences.visMode = mode
        let names: [VisMode: String] = [.spectrum: "SPECTRUM ANALYZER", .oscilloscope: "OSCILLOSCOPE", .off: "OFF"]
        marquee.flash("VISUALIZATION: \(names[mode]!)", for: 1.5)
    }

    // Each option below also switches to the mode it belongs to, so the change is visible.

    @objc func togglePeaks(_ sender: Any?) {
        preferences.showPeaks.toggle()
        preferences.visMode = .spectrum
        marquee.flash("PEAKS: \(preferences.showPeaks ? "ON" : "OFF")", for: 1.5)
    }

    @objc func setBarFalloff(_ sender: NSMenuItem) {
        guard let falloff = choice(Falloff.self, sender) else { return }
        preferences.barFalloff = falloff
        preferences.visMode = .spectrum
        applyFalloff()
        marquee.flash("ANALYZER FALLOFF: \(falloff.rawValue)", for: 1.5)
    }

    @objc func setPeakFalloff(_ sender: NSMenuItem) {
        guard let falloff = choice(Falloff.self, sender) else { return }
        preferences.peakFalloff = falloff
        preferences.visMode = .spectrum
        preferences.showPeaks = true
        applyFalloff()
        marquee.flash("PEAK FALLOFF: \(falloff.rawValue)", for: 1.5)
    }

    @objc func setOscilloscopeStyle(_ sender: NSMenuItem) {
        guard let style = choice(OscilloscopeStyle.self, sender) else { return }
        preferences.oscilloscopeStyle = style
        preferences.visMode = .oscilloscope
        marquee.flash("OSCILLOSCOPE: \(style.rawValue)", for: 1.5)
    }

    private func choice<T: RawRepresentable>(_ type: T.Type, _ item: NSMenuItem) -> T? where T.RawValue == String {
        (item.representedObject as? String).flatMap(T.init(rawValue:))
    }

    private func applyFalloff() {
        engine.analyzer.barFall = preferences.barFalloff.barRate
        engine.analyzer.peakFall = preferences.peakFalloff.peakRate
        engine.analyzer.peakHoldFrames = preferences.peakFalloff.peakHoldFrames
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = item.representedObject as? String
        switch item.action {
        case #selector(toggleShuffle(_:)): item.state = controller.shuffle ? .on : .off
        case #selector(toggleRepeat(_:)): item.state = controller.repeats ? .on : .off
        case #selector(togglePeaks(_:)): item.state = preferences.showPeaks ? .on : .off
        case #selector(setVisMode(_:)): item.state = selected == preferences.visMode.rawValue ? .on : .off
        case #selector(setBarFalloff(_:)): item.state = selected == preferences.barFalloff.rawValue ? .on : .off
        case #selector(setPeakFalloff(_:)): item.state = selected == preferences.peakFalloff.rawValue ? .on : .off
        case #selector(setOscilloscopeStyle(_:)):
            item.state = selected == preferences.oscilloscopeStyle.rawValue ? .on : .off
        case #selector(previousTrack(_:)), #selector(nextTrack(_:)): return controller.queue.count > 0
        case #selector(pause(_:)), #selector(stop(_:)): return engine.track != nil
        default: break
        }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // The menu bar usually claims the letters first; this covers L, which is only in
        // the right-click menu, and anything the menus didn't take.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l": openFiles(nil)
        case "z": previousTrack(nil)
        case "x": play(nil)
        case "c": pause(nil)
        case "v": stop(nil)
        case "b": nextTrack(nil)
        case "s": toggleShuffle(nil)
        case "r": toggleRepeat(nil)
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

    // MARK: - Drag and drop

    /// Dropping replaces the queue and plays; holding Shift adds to it instead.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // This runs repeatedly during a drag, so only scan dropped folders once.
        let changeCount = sender.draggingPasteboard.changeCount
        if dropFileCount?.changeCount != changeCount {
            dropFileCount = (changeCount, AudioFiles.expand(droppedURLs(sender)).count)
        }
        let count = dropFileCount?.count ?? 0
        guard count > 0 else {
            marquee.message = "NO AUDIO FILES THERE"
            return []
        }
        let files = count == 1 ? "1 FILE" : "\(count) FILES"
        marquee.message = NSEvent.modifierFlags.contains(.shift) ? "DROP TO ADD \(files)" : "DROP TO PLAY \(files)"
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        marquee.message = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        marquee.message = nil
        let urls = droppedURLs(sender)
        if NSEvent.modifierFlags.contains(.shift) {
            controller.enqueue(urls)
        } else {
            controller.open(urls)
        }
        return true
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
