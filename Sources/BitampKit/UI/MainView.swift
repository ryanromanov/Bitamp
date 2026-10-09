import AppKit

/// The main window: transport, time, visualizer and marquee. Skins with Orb art get the
/// freeform Orb layout instead of the classic one.
///
/// It's also the first responder for the Playback and Visualization menus, from any
/// Bitamp window, because the other windows never become main.
final class MainView: SkinnedView, NSMenuItemValidation {
    let controller: PlaybackController
    let preferences: Preferences
    /// Shows the open panel.
    var onOpen: (() -> Void)?
    /// Installs and applies a dropped `.wsz` skin.
    var onSkinDropped: ((URL) -> Void)?
    /// Shows the Expansion Paks window.
    var onShowPaks: (() -> Void)?
    /// Installs a dropped `.bitpak`.
    var onPakDropped: ((URL) -> Void)?

    /// Whatever plays the current track: Bitamp's engine or a Pak.
    private var player: PlaybackBackend { controller.player }
    /// Light the EQ and PL buttons as if their windows were open, for screenshots.
    var drawsPanelsAsOpen = false
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
        super.init(pixelSize: skin.orb == nil ? Layout.size : OrbLayout.size, skin: skin, scale: preferences.scale)
        marquee.visibleWidth = Int(marqueeRect.width)
        registerForDraggedTypes([.fileURL])
        applyFalloff()
        announce = { [weak self] message in self?.marquee.message = message }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        if isShaded { return CGSize(width: Layout.size.width, height: ShadeLayout.height) }
        return skin.orb == nil ? Layout.size : OrbLayout.size
    }

    /// The Orb's art, unless it's collapsed to the classic shade strip.
    private var orb: OrbArt? {
        isShaded ? nil : skin.orb
    }

    override var isShapedWindow: Bool { orb != nil }

    override func skinDidChange() {
        marquee.visibleWidth = Int(marqueeRect.width)
        if normalizedPixelSize(pixelSize) != pixelSize { resizeKeepingTopLeft() }
        super.skinDidChange()
    }

    private var marqueeRect: CGRect {
        skin.orb == nil ? Layout.marquee : OrbLayout.marquee
    }

    func flash(_ message: String, for seconds: TimeInterval = 3) {
        marquee.flash(message, for: seconds)
    }

    // MARK: - Frame loop

    override func tick() {
        marquee.setText(titleText)
        marquee.tick()
        controller.engine.analyzer.advance()
    }

    private var titleText: String {
        if let fetching = controller.fetching {
            return "LOADING \(controller.info.displayName(for: fetching))..."
        }
        guard let track = player.nowPlaying else {
            return "BITAMP - DROP FILES OR FOLDERS HERE, OR PRESS L TO OPEN"
        }
        let name = [track.artist, track.title].compactMap { $0 }.joined(separator: " - ")
        let number = controller.queue.currentIndex.map { "\($0 + 1). " } ?? ""
        return "\(number)\(name) (\(TimeFormat.clock(track.duration)))"
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        if isShaded {
            renderShade(c)
            return
        }
        if let orb {
            renderOrb(orb, c)
            return
        }
        c.draw(skin.image(for: .mainBackground), 0, 0)
        c.draw(skin.image(for: .titleBar(active: isActive)), 0, 0)
        for button in TitleButton.allCases {
            c.draw(skin.image(for: .titleButton(button, pressed: isPressed(.title(button)))), at: button.rect.origin)
        }

        drawTime(c, status: Layout.playStatus.origin, minus: Layout.minus.origin, digits: Layout.timeDigits)
        drawVisualizer(c, in: Layout.visualizer)
        drawMarquee(c, in: Layout.marquee)
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

    private func renderOrb(_ orb: OrbArt, _ c: Canvas) {
        c.draw(orb.background(active: isActive), 0, 0)
        for button in TitleButton.allCases {
            c.draw(orb.titleButton(button, pressed: isPressed(.title(button))), at: OrbLayout.titleButton(button).origin)
        }
        drawTime(c, status: OrbLayout.playStatus, minus: OrbLayout.minus, digits: OrbLayout.timeDigits)
        drawVisualizer(c, in: OrbLayout.visualizer)
        drawMarquee(c, in: OrbLayout.marquee)

        // Bitrate, sample rate and channels, one per line beside the time.
        if let track = player.nowPlaying {
            let khz = track.sampleRate.map { "\(Int(($0 / 1000).rounded())) KHZ" } ?? ""
            let channels = track.channels.map { $0 == 1 ? "MONO" : "STEREO" } ?? ""
            let lines = [track.kbps.map { "\($0) KBPS" } ?? "", khz, channels]
            for (index, line) in lines.enumerated() {
                drawPixelText(c, line, Int(OrbLayout.info.x), Int(OrbLayout.info.y) + index * OrbLayout.infoLineHeight)
            }
        }

        // Seek: a filled groove up to the thumb.
        let groove = OrbLayout.positionGroove
        if canSeek, let track = player.nowPlaying {
            let progress = pendingSeek ?? player.currentTime / track.duration
            let x = Int(geometry(for: .position).thumbStart(for: progress))
            c.fill(Int(groove.minX), Int(groove.minY), x - Int(groove.minX), Int(groove.height), orb.fill)
            c.fill(Int(groove.minX), Int(groove.minY), x - Int(groove.minX), 1, orb.fillShine)
            c.draw(orb.positionThumb(pressed: pendingSeek != nil), x, Int(OrbLayout.position.minY) + 1)
        }

        // Volume: filled from the bottom up to the thumb.
        let volumeGroove = OrbLayout.volumeGroove
        let y = Int(geometry(for: .volume).thumbStart(for: controller.volume))
        let thumbBottom = y + Int(OrbLayout.volumeThumb.height)
        let filled = Int(volumeGroove.maxY) - thumbBottom
        c.fill(Int(volumeGroove.minX), thumbBottom, Int(volumeGroove.width), filled, orb.fill)
        c.fill(Int(volumeGroove.minX), thumbBottom, 1, filled, orb.fillShine)
        c.draw(orb.volumeThumb(pressed: slider?.control == .volume), Int(OrbLayout.volume.minX), y)
        if controller.limitation(.volume) != nil { c.dim(OrbLayout.volume) }

        for button in TransportButton.allCases {
            c.draw(orb.transport(button, pressed: isPressed(.transport(button))), at: OrbLayout.rect(of: button).origin)
        }
        for button in OrbLayout.toggles {
            let image = orb.toggle(button, on: isOn(button), pressed: isPressed(.toggle(button)))
            c.draw(image, at: OrbLayout.rect(of: button).origin)
        }
    }

    /// The 14-pixel strip: mini visualizer, time, transport and position.
    private func renderShade(_ c: Canvas) {
        c.draw(skin.image(for: .mainShadeBackground(active: isActive)), 0, 0)
        for button in TitleButton.allCases {
            let pressed = isPressed(.title(button))
            let element: SkinElement = button == .shade
                ? .mainUnshadeButton(pressed: pressed)
                : .titleButton(button, pressed: pressed)
            c.draw(skin.image(for: element), at: button.rect.origin)
        }
        drawShadeVisualizer(c)
        drawShadeTime(c)
        c.draw(skin.image(for: .mainShadePosition), at: ShadeLayout.mainPosition.origin)
        if canSeek, let track = player.nowPlaying {
            let progress = pendingSeek ?? player.currentTime / track.duration
            let x = geometry(for: .position).thumbStart(for: progress)
            c.draw(skin.image(for: .mainShadeThumb(ShadeThumb(progress))), Int(x), Int(ShadeLayout.mainPosition.minY))
        }
    }

    private func drawShadeVisualizer(_ c: Canvas) {
        let rect = ShadeLayout.mainVisualizer
        let (x0, y0, height) = (Int(rect.minX), Int(rect.minY), Int(rect.height))
        let colors = skin.visColors
        c.fill(rect, colors[0])
        let analyzer = controller.engine.analyzer
        switch preferences.visMode {
        case .spectrum:
            for i in 0..<SpectrumAnalyzer.barCount {
                let bar = Int((analyzer.bars[i] * Float(height)).rounded())
                for row in (height - bar)..<height {
                    // Pick from the full 16-row palette so the colors match the big analyzer.
                    c.fill(x0 + i * 2, y0 + row, 2, 1, colors[2 + row * 15 / (height - 1)])
                }
            }
        case .oscilloscope:
            for x in 0..<Int(rect.width) {
                let sample = analyzer.waveform[x * 2]
                let y = min(max(height / 2 - Int((sample * Float(height / 2)).rounded()), 0), height - 1)
                c.fill(x0 + x, y0 + y, 1, 1, colors[18])
            }
        case .off:
            break
        }
    }

    private func drawShadeTime(_ c: Canvas) {
        let blinkOff = player.state == .paused && frameCount / 15 % 2 == 1
        guard let track = player.nowPlaying, player.state != .stopped, !blinkOff else { return }
        let elapsed = currentTime(of: track)
        let showRemaining = preferences.showRemaining
        let digits = TimeFormat.lcdDigits(showRemaining ? max(0, track.duration - elapsed) : elapsed)
        let characters: [Character] = [showRemaining ? "-" : " "] + digits.map { Character(String($0)) }
        for (character, x) in zip(characters, ShadeLayout.mainTimeGlyphs) {
            c.draw(skin.glyph(for: character), x, ShadeLayout.mainTimeY)
        }
    }

    private func isPressed(_ control: Control) -> Bool {
        pressed == control && pressedInside
    }

    private func isOn(_ button: ToggleButton) -> Bool {
        switch button {
        case .shuffle: return controller.shuffle
        case .repeatTrack: return controller.repeats
        case .equalizer: return drawsPanelsAsOpen || windowGroup?.isVisible(.equalizer) ?? false
        case .playlist: return drawsPanelsAsOpen || windowGroup?.isVisible(.playlist) ?? false
        }
    }

    private func drawTime(_ c: Canvas, status statusOrigin: CGPoint, minus: CGPoint, digits: [CGPoint]) {
        let status: PlayStatus
        switch player.state {
        case .playing: status = .playing
        case .paused: status = .paused
        case .stopped: status = .stopped
        }
        c.draw(skin.image(for: .playStatus(status)), at: statusOrigin)

        // Blank while stopped, and blinking while paused.
        let blinkOff = player.state == .paused && frameCount / 15 % 2 == 1
        guard let track = player.nowPlaying, player.state != .stopped, !blinkOff else {
            for point in digits {
                c.draw(skin.image(for: .digit(SkinElement.blankDigit)), at: point)
            }
            return
        }
        let elapsed = currentTime(of: track)
        let showRemaining = preferences.showRemaining
        let shown = showRemaining ? max(0, track.duration - elapsed) : elapsed
        if showRemaining {
            c.draw(skin.image(for: .minus), at: minus)
        }
        for (digit, point) in zip(TimeFormat.lcdDigits(shown), digits) {
            c.draw(skin.image(for: .digit(digit)), at: point)
        }
    }

    /// The player's position, or where the user is dragging the position thumb.
    private func currentTime(of track: NowPlaying) -> Double {
        if let pendingSeek { return pendingSeek * track.duration }
        return player.currentTime
    }

    /// The Pak playing audio Bitamp can't see, which the visualizer names instead of
    /// lying flat.
    private var badgePak: Pak? {
        guard player.state != .stopped, !player.capabilities.contains(.visualizer) else { return nil }
        return controller.playingPak
    }

    /// A small cartridge and the Pak's name, in the visualizer's colors so any skin suits it.
    private func drawPakBadge(_ c: Canvas, _ pak: Pak, in rect: CGRect) {
        let colors = skin.visColors
        let (x0, y0, height) = (Int(rect.minX), Int(rect.minY), Int(rect.height))
        let top = y0 + (height - 12) / 2
        // The cartridge: 9×12, shoulders, ridges and a label.
        let body = colors[2 + 15 / 2], label = colors[2]
        c.fill(x0 + 3, top, 9, 12, body)
        c.fill(x0 + 5, top + 1, 5, 1, colors[0])
        c.fill(x0 + 4, top + 4, 7, 5, label)
        c.fill(x0 + 3, top + 11, 1, 1, colors[0])
        c.fill(x0 + 11, top + 11, 1, 1, colors[0])

        let textX = x0 + 16
        let fit = max(0, (Int(rect.width) - 17) / PixelFont.cellWidth)
        let name = String(pak.name.uppercased().prefix(fit))
        if height >= 14 {
            c.text(name, textX, y0 + height / 2 - 6, colors[2])
            c.text("PAK", textX, y0 + height / 2 + 1, colors[2 + 15 / 2])
        } else {
            c.text(name, textX, y0 + (height - 5) / 2, colors[2])
        }
    }

    /// The analyzer or oscilloscope in `rect`, which is 16 pixels tall; wider rects get
    /// wider bars and a stretched waveform.
    private func drawVisualizer(_ c: Canvas, in rect: CGRect) {
        let (x0, y0) = (Int(rect.minX), Int(rect.minY))
        let colors = skin.visColors
        c.fill(rect, colors[0])
        if let pak = badgePak {
            drawPakBadge(c, pak, in: rect)
            return
        }
        let mode = preferences.visMode
        guard mode != .off else { return }
        for y in stride(from: 1, to: Int(rect.height), by: 2) {
            for x in stride(from: 1, to: Int(rect.width), by: 2) {
                c.fill(x0 + x, y0 + y, 1, 1, colors[1])
            }
        }

        let height = Int(rect.height)
        let analyzer = controller.engine.analyzer
        switch mode {
        case .spectrum:
            let showPeaks = preferences.showPeaks
            let step = (Int(rect.width) + 1) / SpectrumAnalyzer.barCount
            for i in 0..<SpectrumAnalyzer.barCount {
                let x = x0 + i * step
                let bar = Int((analyzer.bars[i] * Float(height)).rounded())
                for row in (height - bar)..<height {
                    c.fill(x, y0 + row, step - 1, 1, colors[2 + row])
                }
                let peak = Int((analyzer.peaks[i] * Float(height)).rounded())
                if showPeaks && peak > 0 {
                    c.fill(x, y0 + height - peak, step - 1, 1, colors[23])
                }
            }
        case .oscilloscope:
            let middle = height / 2
            let style = preferences.oscilloscopeStyle
            var previous: Int?
            let waveform = analyzer.waveform
            for x in 0..<Int(rect.width) {
                let sample = waveform[x * waveform.count / Int(rect.width)]
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

    private func drawMarquee(_ c: Canvas, in rect: CGRect) {
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
        guard let track = player.nowPlaying else {
            c.draw(skin.image(for: .mono(active: false)), at: Layout.mono.origin)
            c.draw(skin.image(for: .stereo(active: false)), at: Layout.stereo.origin)
            return
        }
        if let kbps = track.kbps {
            // Three characters at most; 1411 reads "14H" (hundreds).
            let text = kbps < 1000 ? String(kbps) : "\(kbps / 100)H"
            drawRightAligned(c, text, in: Layout.kbps)
        }
        if let sampleRate = track.sampleRate {
            let khz = Int((sampleRate / 1000).rounded())
            drawRightAligned(c, String(String(khz).prefix(2)), in: Layout.khz)
        }
        c.draw(skin.image(for: .mono(active: track.channels == 1)), at: Layout.mono.origin)
        c.draw(skin.image(for: .stereo(active: (track.channels ?? 0) > 1)), at: Layout.stereo.origin)
    }

    private func drawRightAligned(_ c: Canvas, _ text: String, in rect: CGRect) {
        let width = PixelFont.width(of: text)
        drawPixelText(c, text, Int(rect.maxX) - width, Int(rect.minY))
    }

    private func drawSliders(_ c: Canvas) {
        let lastLevel = Double(SkinElement.sliderLevels - 1)

        let volumeLevel = Int((controller.volume * lastLevel).rounded())
        c.draw(skin.image(for: .volumeBackground(level: volumeLevel)), at: Layout.volume.origin)
        let volumeX = SliderGeometry.volume.thumbStart(for: controller.volume)
        c.draw(skin.image(for: .volumeThumb(pressed: slider?.control == .volume)), Int(volumeX), Int(Layout.volume.minY) + 1)

        let balanceLevel = Int((abs(controller.balance) * lastLevel).rounded())
        c.draw(skin.image(for: .balanceBackground(level: balanceLevel)), at: Layout.balance.origin)
        let balanceX = SliderGeometry.balance.thumbStart(for: BalanceMapping.slider(fromBalance: controller.balance))
        c.draw(skin.image(for: .balanceThumb(pressed: slider?.control == .balance)), Int(balanceX), Int(Layout.balance.minY) + 1)

        if controller.limitation(.volume) != nil {
            c.dim(Layout.volume)
            c.dim(Layout.balance)
        }

        c.draw(skin.image(for: .positionBackground), at: Layout.position.origin)
        if canSeek, let track = player.nowPlaying {
            let progress = pendingSeek ?? player.currentTime / track.duration
            let x = SliderGeometry.position.thumbStart(for: progress)
            c.draw(skin.image(for: .positionThumb(pressed: pendingSeek != nil)), Int(x), Int(Layout.position.minY))
        }
    }

    private var canSeek: Bool {
        player.state != .stopped && (player.nowPlaying?.duration ?? 0) > 0
    }

    // MARK: - Mouse

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let control = control(at: point) else {
            // Double-clicking the title bar toggles shade mode; in shade mode it's all title bar.
            let titleBar = skin.orb == nil ? Layout.titleBar : OrbLayout.titleBar
            if event.clickCount == 2 && (isShaded || titleBar.contains(point)) {
                toggleShade(nil)
                return true
            }
            return false
        }
        switch control {
        case .volume, .balance:
            if let limitation = controller.limitation(.volume) {
                marquee.flash(limitation, for: 2)
            } else {
                beginSliderDrag(control, at: point)
            }
        case .position:
            beginSliderDrag(control, at: point)
        case .timeDisplay:
            preferences.showRemaining.toggle()
        case .visualizer where badgePak != nil:
            onShowPaks?()
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
            pressedInside = control(at: point) == pressed
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        if let slider {
            if slider.control == .position, let pendingSeek, let track = player.nowPlaying {
                player.seek(to: pendingSeek * track.duration)
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
        control(at: pixel(for: event)) == .visualizer ? Menus.visualization() : Menus.context()
    }

    private func control(at point: CGPoint) -> Control? {
        if isShaded { return ShadeLayout.mainControl(at: point) }
        return orb == nil ? Layout.control(at: point) : OrbLayout.control(at: point)
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
        nudgeVolume(by: Double(event.scrollingDeltaY) * step)
    }

    private func geometry(for control: Control) -> SliderGeometry {
        if orb != nil {
            switch control {
            case .volume:
                return SliderGeometry(track: OrbLayout.volume, thumbWidth: OrbLayout.volumeThumb.height, vertical: true)
            case .position:
                return SliderGeometry(track: OrbLayout.position, thumbWidth: OrbLayout.positionThumb.width)
            default: break
            }
        }
        switch control {
        case .volume: return .volume
        case .balance: return .balance
        default:
            return isShaded ? SliderGeometry(track: ShadeLayout.mainPosition, thumbWidth: ShadeLayout.thumb.width) : .position
        }
    }

    private func sliderValue(for control: Control) -> Double {
        switch control {
        case .volume: return controller.volume
        case .balance: return BalanceMapping.slider(fromBalance: controller.balance)
        default:
            guard let track = player.nowPlaying, track.duration > 0 else { return 0 }
            return player.currentTime / track.duration
        }
    }

    private func beginSliderDrag(_ control: Control, at point: CGPoint) {
        if control == .position && !canSeek { return }
        let geometry = geometry(for: control)
        let thumbStart = geometry.thumbStart(for: sliderValue(for: control))
        let along = geometry.along(point)
        // Grab the thumb where it was clicked; a click on the track centers the thumb there.
        let grab = (thumbStart..<thumbStart + geometry.thumbWidth).contains(along)
            ? along - thumbStart
            : (geometry.thumbWidth / 2).rounded(.down)
        slider = (control, grab)
        updateSlider(at: point)
    }

    private func updateSlider(at point: CGPoint) {
        guard let slider else { return }
        let geometry = geometry(for: slider.control)
        let value = geometry.value(forThumbStart: geometry.along(point) - slider.grab)
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
            guard let track = player.nowPlaying else { return }
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
        if let limitation = controller.limitation(.volume) {
            marquee.flash(limitation, for: 2)
            return
        }
        controller.volume += amount
        marquee.flash(volumeMessage, for: 1)
    }

    private func perform(_ control: Control) {
        switch control {
        case .title(.options):
            let button = orb == nil ? TitleButton.options.rect : OrbLayout.titleButton(.options)
            let below = NSPoint(x: button.minX * scale, y: bounds.height - button.maxY * scale)
            Menus.context().popUp(positioning: nil, at: below, in: self)
        case .title(.close): NSApp.terminate(nil)
        case .title(.minimize): window?.miniaturize(nil)
        case .title(.shade): toggleShade(nil)
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
        default: break
        }
    }

    // MARK: - Menu actions

    @objc func openFiles(_ sender: Any?) { onOpen?() }

    @objc func toggleShade(_ sender: Any?) {
        if let window { windowGroup?.toggleShade(window) }
    }
    @objc func previousTrack(_ sender: Any?) { controller.previous() }
    @objc func nextTrack(_ sender: Any?) { controller.next() }
    @objc func pause(_ sender: Any?) { player.pause() }
    @objc func stop(_ sender: Any?) { controller.stop() }

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

    @objc func setRetroSound(_ sender: NSMenuItem) {
        guard let sound = choice(RetroSound.self, sender) else { return }
        applyRetroSound(sound)
    }

    /// Steps through off, crush and chiptune; the T key.
    @objc func cycleRetroSound(_ sender: Any?) {
        let all = RetroSound.allCases
        applyRetroSound(all[(all.firstIndex(of: controller.retroSound)! + 1) % all.count])
    }

    /// How much of the song plays under the chiptune cover; it also switches the cover on.
    @objc func setChipBlend(_ sender: NSMenuItem) {
        guard let blend = choice(ChipBlend.self, sender), retroSoundReachesTheSong() else { return }
        controller.chipBlend = blend
        controller.retroSound = .chiptune
        let names: [ChipBlend: String] = [.none: "NONE", .low: "20%", .medium: "40%"]
        marquee.flash("CHIPTUNE, ORIGINAL SONG: \(names[blend]!)", for: 1.5)
    }

    /// The Retro Sound menu's note on why its choices are greyed out; never chosen.
    @objc func retroSoundNote(_ sender: Any?) {}

    /// False, after saying why, while a Pak that plays its own audio is on.
    private func retroSoundReachesTheSong() -> Bool {
        guard let limitation = controller.limitation(.retroSound) else { return true }
        marquee.flash(limitation, for: 2)
        return false
    }

    private func applyRetroSound(_ sound: RetroSound) {
        guard retroSoundReachesTheSong() else { return }
        controller.retroSound = sound
        let names: [RetroSound: String] = [.off: "OFF", .crush: "8-BIT CRUSH", .chiptune: "CHIPTUNE (EXPERIMENTAL)"]
        marquee.flash("RETRO SOUND: \(names[sound]!)", for: 1.5)
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
        controller.engine.analyzer.barFall = preferences.barFalloff.barRate
        controller.engine.analyzer.peakFall = preferences.peakFalloff.peakRate
        controller.engine.analyzer.peakHoldFrames = preferences.peakFalloff.peakHoldFrames
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = item.representedObject as? String
        switch item.action {
        case #selector(toggleShuffle(_:)): item.state = controller.shuffle ? .on : .off
        case #selector(toggleRepeat(_:)): item.state = controller.repeats ? .on : .off
        // Greyed out, still showing the setting, while a Pak plays its own audio.
        case #selector(setRetroSound(_:)):
            item.state = selected == controller.retroSound.rawValue ? .on : .off
            return controller.limitation(.retroSound) == nil
        case #selector(setChipBlend(_:)):
            item.state = selected == controller.chipBlend.rawValue ? .on : .off
            return controller.limitation(.retroSound) == nil
        case #selector(retroSoundNote(_:)):
            let limitation = controller.limitation(.retroSound)
            item.isHidden = limitation == nil
            item.title = "Not available while \(controller.playingPak?.name ?? "this song") plays"
            return false
        case #selector(toggleShade(_:)):
            item.state = isShaded ? .on : .off
            return window?.isVisible == true
        case #selector(togglePeaks(_:)): item.state = preferences.showPeaks ? .on : .off
        case #selector(setVisMode(_:)): item.state = selected == preferences.visMode.rawValue ? .on : .off
        case #selector(setBarFalloff(_:)): item.state = selected == preferences.barFalloff.rawValue ? .on : .off
        case #selector(setPeakFalloff(_:)): item.state = selected == preferences.peakFalloff.rawValue ? .on : .off
        case #selector(setOscilloscopeStyle(_:)):
            item.state = selected == preferences.oscilloscopeStyle.rawValue ? .on : .off
        case #selector(previousTrack(_:)), #selector(nextTrack(_:)): return controller.queue.count > 0
        case #selector(pause(_:)), #selector(stop(_:)): return player.nowPlaying != nil
        default: break
        }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // The menu bar usually claims the letters first; this covers L, which is only in
        // the right-click menu, and anything the menus didn't take. Letters held with
        // Option, Control or Command aren't these shortcuts (Option-R is Regroup Windows).
        let modified = !event.modifierFlags.intersection([.option, .control, .command]).isEmpty
        switch modified ? nil : event.charactersIgnoringModifiers?.lowercased() {
        case "l": openFiles(nil)
        case "z": previousTrack(nil)
        case "x": play(nil)
        case "c": pause(nil)
        case "v": stop(nil)
        case "b": nextTrack(nil)
        case "s": toggleShuffle(nil)
        case "r": toggleRepeat(nil)
        case "t": cycleRetroSound(nil)
        default:
            switch event.specialKey {
            case .leftArrow?: player.seek(to: player.currentTime - 5)
            case .rightArrow?: player.seek(to: player.currentTime + 5)
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
        if droppedURLs(sender).contains(where: SkinLibrary.isSkin) {
            marquee.message = "DROP TO LOAD SKIN"
            return .copy
        }
        if droppedURLs(sender).contains(where: PakLibrary.isPak) {
            marquee.message = "DROP TO INSTALL EXPANSION PAK"
            return .copy
        }
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
        if let skin = urls.first(where: SkinLibrary.isSkin) {
            onSkinDropped?(skin)
            return true
        }
        if let pak = urls.first(where: PakLibrary.isPak) {
            DispatchQueue.main.async { [weak self] in self?.onPakDropped?(pak) }
            return true
        }
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
