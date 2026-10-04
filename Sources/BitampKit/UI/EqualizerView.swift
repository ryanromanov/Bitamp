import AppKit

/// Maps a vertical EQ slider's thumb to decibels and back. The top is +12 dB.
struct VerticalSliderGeometry {
    let track: CGRect
    let thumbHeight: CGFloat
    /// Values this close to 0 dB snap to it, so flat is easy to hit.
    static let snap: Float = 0.6

    var travel: CGFloat { track.height - thumbHeight }

    func thumbY(for decibels: Float) -> CGFloat {
        let range = EqualizerSettings.range
        let t = CGFloat((EqualizerSettings.clamp(decibels) - range.lowerBound) / (range.upperBound - range.lowerBound))
        return track.minY + (travel * (1 - t)).rounded()
    }

    func decibels(forThumbY y: CGFloat) -> Float {
        let range = EqualizerSettings.range
        let t = Float(1 - min(max((y - track.minY) / travel, 0), 1))
        let value = range.lowerBound + t * (range.upperBound - range.lowerBound)
        return abs(value) < Self.snap ? 0 : value
    }
}

/// The 10-band equalizer window.
final class EqualizerView: SkinnedView {
    let controller: PlaybackController
    private var pressed: EQLayout.Control?
    private var pressedInside = false
    /// The slider being dragged, and where on its thumb it was grabbed.
    private var slider: (control: EQLayout.Control, grab: CGFloat)?

    /// In shade mode the strip has tiny volume and balance sliders instead.
    private enum ShadeSlider {
        case volume, balance

        var geometry: SliderGeometry {
            SliderGeometry(track: self == .volume ? ShadeLayout.eqVolume : ShadeLayout.eqBalance,
                           thumbWidth: ShadeLayout.thumb.width)
        }
    }
    private var shadeSlider: ShadeSlider?

    init(controller: PlaybackController, skin: Skin, scale: CGFloat) {
        self.controller = controller
        super.init(pixelSize: EQLayout.size, skin: skin, scale: scale)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        isShaded ? CGSize(width: EQLayout.size.width, height: ShadeLayout.height) : EQLayout.size
    }

    private var settings: EqualizerSettings {
        get { controller.equalizer }
        set { controller.equalizer = newValue }
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        if isShaded {
            renderShade(c)
            return
        }
        c.draw(skin.image(for: .eqBackground), 0, 0)
        c.draw(skin.image(for: .eqTitleBar(active: isActive)), 0, 0)
        c.draw(skin.image(for: .eqShadeButton(pressed: isPressed(.shade))), at: ShadeLayout.eqShadeButton.origin)
        c.draw(skin.image(for: .eqCloseButton(pressed: isPressed(.close))), at: EQLayout.close.origin)
        for button in [EQButton.on, .auto, .presets] {
            let on = button == .on && settings.enabled
            c.draw(skin.image(for: .eqButton(button, on: on, pressed: isPressed(.button(button)))), at: EQLayout.button(button).origin)
        }
        drawGraph(c)
        drawSlider(c, .preamp, settings.preamp)
        for (index, gain) in settings.bands.enumerated() {
            drawSlider(c, .band(index), gain)
        }
    }

    private func renderShade(_ c: Canvas) {
        c.draw(skin.image(for: .eqShadeBackground(active: isActive)), 0, 0)
        c.draw(skin.image(for: .eqUnshadeButton(pressed: isPressed(.shade))), at: ShadeLayout.eqShadeButton.origin)
        c.draw(skin.image(for: .eqShadeCloseButton(pressed: isPressed(.close))), at: EQLayout.close.origin)
        let volume = controller.volume
        let balance = BalanceMapping.slider(fromBalance: controller.balance)
        let y = Int(ShadeLayout.eqVolume.minY)
        c.draw(skin.image(for: .eqShadeVolumeThumb(ShadeThumb(volume))),
               Int(ShadeSlider.volume.geometry.thumbStart(for: volume)), y)
        c.draw(skin.image(for: .eqShadeBalanceThumb(ShadeThumb(balance))),
               Int(ShadeSlider.balance.geometry.thumbStart(for: balance)), y)
    }

    private func isPressed(_ control: EQLayout.Control) -> Bool {
        pressed == control && pressedInside
    }

    private func drawSlider(_ c: Canvas, _ control: EQLayout.Control, _ decibels: Float) {
        let rect = control.rect
        let range = EqualizerSettings.range
        let t = (decibels - range.lowerBound) / (range.upperBound - range.lowerBound)
        let level = Int((t * Float(SkinElement.sliderLevels - 1)).rounded())
        c.draw(skin.image(for: .eqSliderBackground(level: level)), at: rect.origin)
        let geometry = VerticalSliderGeometry(track: rect, thumbHeight: EQLayout.thumb.height)
        let thumb = skin.image(for: .eqSliderThumb(pressed: slider?.control == control))
        c.draw(thumb, Int(rect.minX) + 1, Int(geometry.thumbY(for: decibels)))
    }

    /// The response curve: a smooth line through the ten bands, plus the preamp level.
    private func drawGraph(_ c: Canvas) {
        let rect = EQLayout.graph
        let (x0, y0) = (Int(rect.minX), Int(rect.minY))
        let height = Int(rect.height)
        c.draw(skin.image(for: .eqGraphBackground), x0, y0)

        func row(_ decibels: Float) -> Int {
            let t = (decibels - EqualizerSettings.range.lowerBound) / 24
            return min(max(Int(((1 - t) * Float(height - 1)).rounded()), 0), height - 1)
        }
        c.draw(skin.image(for: .eqPreampLine), x0, y0 + row(settings.preamp))

        let colors = skin.eqGraphColors
        let curve = Self.curve(settings.bands, width: Int(rect.width))
        var previous: Int?
        for (x, decibels) in curve.enumerated() {
            let y = row(decibels)
            for r in min(y, previous ?? y)...max(y, previous ?? y) {
                c.fill(x0 + x, y0 + r, 1, 1, colors[min(r, colors.count - 1)])
            }
            previous = y
        }
    }

    /// Catmull-Rom interpolation through the band values, sampled at `width` points.
    static func curve(_ bands: [Float], width: Int) -> [Float] {
        guard bands.count > 1, width > 1 else { return [Float](repeating: bands.first ?? 0, count: max(width, 0)) }
        let last = bands.count - 1
        return (0..<width).map { x in
            let position = Float(x) / Float(width - 1) * Float(last)
            let i = min(Int(position), last - 1)
            let t = position - Float(i)
            let p0 = bands[max(i - 1, 0)], p1 = bands[i], p2 = bands[i + 1], p3 = bands[min(i + 2, last)]
            let t2 = t * t, t3 = t2 * t
            let value = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
            return EqualizerSettings.clamp(value)
        }
    }

    // MARK: - Mouse

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        if isShaded { return shadeMouseDown(at: point, event: event) }
        guard let control = EQLayout.control(at: point) else {
            if event.clickCount == 2 && EQLayout.titleBar.contains(point) {
                windowGroup?.toggleShade(.equalizer)
                return true
            }
            return false
        }
        switch control {
        case .preamp, .band:
            let geometry = VerticalSliderGeometry(track: control.rect, thumbHeight: EQLayout.thumb.height)
            let thumbY = geometry.thumbY(for: value(of: control))
            let grab = (thumbY..<thumbY + EQLayout.thumb.height).contains(point.y)
                ? point.y - thumbY
                : (EQLayout.thumb.height / 2).rounded(.down)
            slider = (control, grab)
            updateSlider(at: point)
        case .button(.presets):
            let rect = viewRect(forPixels: EQLayout.button(.presets))
            presetsMenu().popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
        default:
            pressed = control
            pressedInside = true
        }
        return true
    }

    private func shadeMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        if ShadeLayout.eqShadeButton.contains(point) {
            pressed = .shade
        } else if EQLayout.close.contains(point) {
            pressed = .close
        } else if ShadeLayout.eqVolume.contains(point) {
            shadeSlider = .volume
        } else if ShadeLayout.eqBalance.contains(point) {
            shadeSlider = .balance
        } else if event.clickCount == 2 {
            windowGroup?.toggleShade(.equalizer)
            return true
        } else {
            return false
        }
        pressedInside = pressed != nil
        updateShadeSlider(at: point)
        return true
    }

    private func updateShadeSlider(at point: CGPoint) {
        guard let shadeSlider else { return }
        let value = shadeSlider.geometry.value(forThumbStart: point.x - 1)
        switch shadeSlider {
        case .volume:
            controller.volume = value
            announce?("VOLUME: \(Int((controller.volume * 100).rounded()))%")
        case .balance:
            controller.balance = BalanceMapping.balance(fromSlider: value)
            let balance = controller.balance
            announce?(balance == 0
                ? "BALANCE: CENTER"
                : "BALANCE: \(Int((abs(balance) * 100).rounded()))% \(balance < 0 ? "LEFT" : "RIGHT")")
        }
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        if shadeSlider != nil {
            updateShadeSlider(at: point)
        } else if slider != nil {
            updateSlider(at: point)
        } else if let pressed {
            pressedInside = pressed.rect.contains(point)
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        if slider != nil || shadeSlider != nil {
            slider = nil
            shadeSlider = nil
            announce?(nil)
        } else if let pressed, pressedInside {
            switch pressed {
            case .close: windowGroup?.setVisible(.equalizer, false)
            case .shade: windowGroup?.toggleShade(.equalizer)
            case .button(.on):
                settings.enabled.toggle()
                announce?(nil)
            default: break  // AUTO (per-track presets) comes later.
            }
        }
        pressed = nil
        pressedInside = false
    }

    private func value(of control: EQLayout.Control) -> Float {
        switch control {
        case .band(let index): return settings.bands[index]
        default: return settings.preamp
        }
    }

    private func updateSlider(at point: CGPoint) {
        guard let slider else { return }
        let geometry = VerticalSliderGeometry(track: slider.control.rect, thumbHeight: EQLayout.thumb.height)
        let decibels = geometry.decibels(forThumbY: point.y - slider.grab)
        switch slider.control {
        case .band(let index):
            settings.bands[index] = decibels
            announce?("EQ: \(EqualizerLabels.names[index]) \(EqualizerLabels.decibels(decibels))")
        default:
            settings.preamp = decibels
            announce?("PREAMP: \(EqualizerLabels.decibels(decibels))")
        }
    }

    // MARK: - Presets

    private func presetsMenu() -> NSMenu {
        let menu = NSMenu(title: "Presets")
        for preset in EqualizerPreset.builtIn {
            menu.addItem(presetItem(preset))
        }
        let custom = controller.customPresets
        if !custom.isEmpty {
            menu.addItem(.separator())
            custom.forEach { menu.addItem(presetItem($0)) }
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save Preset…", action: #selector(savePreset(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !custom.isEmpty {
            let delete = NSMenu(title: "Delete Preset")
            for preset in custom {
                let item = NSMenuItem(title: preset.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.name
                delete.addItem(item)
            }
            menu.addItem(Menus.submenu(delete))
        }
        return menu
    }

    private func presetItem(_ preset: EqualizerPreset) -> NSMenuItem {
        let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset.name
        let applied = preset.apply(to: settings)
        item.state = applied.preamp == settings.preamp && applied.bands == settings.bands ? .on : .off
        return item
    }

    private func preset(named name: String?) -> EqualizerPreset? {
        (controller.customPresets + EqualizerPreset.builtIn).first { $0.name == name }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let preset = preset(named: sender.representedObject as? String) else { return }
        settings = preset.apply(to: settings)
        if let main = windowGroup?.main.contentView as? MainView {
            main.flash("EQ PRESET: \(preset.name)", for: 2)
        }
    }

    @objc private func savePreset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Save Equalizer Preset"
        alert.informativeText = "Name this preset. Using an existing custom preset's name replaces it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "My Preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var custom = controller.customPresets.filter { $0.name != name }
        custom.append(EqualizerPreset(name: name, preamp: settings.preamp, bands: settings.bands))
        controller.customPresets = custom
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        controller.customPresets.removeAll { $0.name == name }
    }
}
