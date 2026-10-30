import AppKit

/// Where things sit in the Liner Notes window, in skin pixels.
enum LinerNotesLayout {
    /// As wide as the main window, docking under the playlist.
    static let defaultSize = CGSize(width: 275, height: 20 + 7 * 29 + 12)
    static let minSize = CGSize(width: 275, height: 20 + 5 * 29 + 12)
    static let widthStep: CGFloat = 25
    static let heightStep = PlaylistLayout.heightStep
    static let cover = 32
    static let barHeight = 13
    static let gripSize = CGSize(width: 20, height: 20)

    static func snapped(_ size: CGSize) -> CGSize {
        func snap(_ value: CGFloat, _ minimum: CGFloat, _ step: CGFloat) -> CGFloat {
            minimum + max(0, ((value - minimum) / step).rounded()) * step
        }
        return CGSize(width: snap(size.width, minSize.width, widthStep), height: snap(size.height, minSize.height, heightStep))
    }

    struct Parts {
        let content: CGRect
        let scrollTrack: CGRect
        let left: Int
        let right: Int
        let header: CGRect
        let body: CGRect
        let bar: CGRect
        let grip: CGRect

        init(size: CGSize, gen: Bool) {
            content = PanelFrame.content(in: size, gen: gen)
            scrollTrack = PanelFrame.scrollTrack(in: size, gen: gen)
            left = Int(content.minX) + 4
            right = Int(scrollTrack.minX) - 3
            header = CGRect(x: left, y: Int(content.minY) + 4, width: right - left, height: cover)
            let barY = Int(content.maxY) - barHeight - 2
            bar = CGRect(x: left, y: barY, width: right - left, height: barHeight)
            let bodyTop = Int(header.maxY) + 6
            body = CGRect(x: left, y: bodyTop, width: right - left, height: barY - 5 - bodyTop)
            grip = CGRect(x: size.width - gripSize.width, y: size.height - gripSize.height,
                          width: gripSize.width, height: gripSize.height)
        }
    }
}

/// The Liner Notes window: the song that's playing, and notes about it with numbered
/// sources, from the Liner Notes Pak. Along the bottom, when to look songs up (AUTO, ASK,
/// OFF); the setup (service, model, key) shows in the window when there's no key yet, or
/// when the service line under the title is clicked.
final class LinerNotesView: SkinnedView {
    let session: LinerNotesSession
    let paks: PakRegistry
    private var pak: LinerNotesPak { session.pak }
    /// Gets keys the window doesn't use, such as the transport letters.
    weak var keyFallback: NSResponder?

    private var keyBox: PixelTextBox!
    /// Showing the setup though there's a key, to change it.
    private var settingUp = false
    /// The setup's choices before they're saved.
    private var draftProvider: String?
    private var draftModel: String?

    private var scroll: CGFloat = 0 {
        didSet {
            scroll = min(max(scroll, 0), max(0, CGFloat(contentHeight) - parts.body.height))
            if scroll != oldValue { needsDisplay = true }
        }
    }
    private var contentHeight = 0
    /// Where each source's line was drawn last, for clicks.
    private var sourceRects: [(CGRect, URL)] = []
    /// Buttons drawn last frame, for clicks.
    private var buttons: [(CGRect, Button)] = []

    private enum Button: Equatable {
        case lookup(LinerNotesPak.Lookup), askAgain, ask, setUp, provider(String), model(String), save, cancel
    }

    private enum Press: Equatable {
        case close, grip(startSize: CGSize, startMouse: NSPoint), thumb(grab: CGFloat), key, button(Button), source(URL)
    }
    private var pressed: Press?
    private var pressedInside = false

    init(session: LinerNotesSession, paks: PakRegistry, skin: Skin, scale: CGFloat) {
        self.session = session
        self.paks = paks
        super.init(pixelSize: LinerNotesLayout.defaultSize, skin: skin, scale: scale)
        keyBox = PixelTextBox(in: self, rect: .zero, placeholder: "Paste your API key", secure: true)
        keyBox.onSubmit = { [weak self] _ in self?.saveSetup() }
        session.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        LinerNotesLayout.snapped(proposed)
    }

    /// Redraws every frame only while something moves: the countdown, notes arriving, or
    /// the key box's caret.
    override var redrawsEveryFrame: Bool {
        keyBox?.isEditing == true || session.phase == .looking || session.phase == .waiting
    }

    private var parts: LinerNotesLayout.Parts {
        LinerNotesLayout.Parts(size: pixelSize, gen: skin.gen != nil)
    }

    private var isInserted: Bool { paks.isInserted(pak) }

    override func tick() {
        // Follows the song only while the window is open, so a closed window costs nothing.
        guard window?.isVisible == true else { return }
        session.update(active: isInserted)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
    }

    /// The Pak's settings changed, here or in its Settings… form.
    func settingsChanged() {
        session.settingsChanged()
        needsDisplay = true
    }

    private var showsSetup: Bool { settingUp || session.phase == .needsSetup }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        let parts = self.parts
        let colors = skin.playlistColors
        let dim = mix(colors.normal, colors.normalBackground, 0.45)
        let rule = mix(colors.normalBackground, colors.normal, 0.25)
        buttons = []
        sourceRects = []
        PanelFrame(skin: skin, size: pixelSize, title: "LINER NOTES", active: isActive)
            .draw(c, closePressed: pressed == .close && pressedInside)
        c.fill(skin.gen == nil ? CGRect(x: parts.content.minX, y: parts.content.minY,
                                        width: parts.scrollTrack.minX - parts.content.minX, height: parts.content.height)
                               : parts.content, colors.normalBackground)

        drawHeader(c, parts, colors, dim)
        c.fill(parts.left, Int(parts.header.maxY) + 2, parts.right - parts.left, 1, rule)
        drawBar(c, parts, colors, dim)
        c.fill(Int(parts.content.minX), Int(parts.bar.minY) - 3, parts.right - Int(parts.content.minX) + 3, 1, rule)

        c.context.saveGState()
        c.context.clip(to: parts.body)
        keyBox.rect = .zero
        contentHeight = drawBody(c, parts, colors, dim, top: Int(parts.body.minY) - Int(scroll.rounded()))
        c.context.restoreGState()
        if keyBox.rect != .zero { keyBox.draw(c, skin: skin, frameCount: frameCount) }
        if CGFloat(contentHeight) > parts.body.height {
            c.draw(skin.image(for: .playlistScrollThumb(pressed: isDraggingThumb)), at: thumbRect.origin)
        }
    }

    private var isDraggingThumb: Bool {
        if case .thumb? = pressed { return true }
        return false
    }

    private var thumbRect: CGRect {
        let track = parts.scrollTrack
        let travel = track.height - PlaylistLayout.scrollThumb.height
        let limit = max(1, CGFloat(contentHeight) - parts.body.height)
        return CGRect(origin: CGPoint(x: track.minX, y: track.minY + (travel * scroll / limit).rounded()), size: PlaylistLayout.scrollThumb)
    }

    private func drawHeader(_ c: Canvas, _ parts: LinerNotesLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        let x = parts.left, y = Int(parts.header.minY), size = LinerNotesLayout.cover
        let light = mix(colors.normalBackground, colors.normal, 0.25), dark = mix(colors.normalBackground, rgb(0), 0.4)
        if let artwork = session.artwork {
            c.context.saveGState()
            c.context.interpolationQuality = .medium
            c.context.translateBy(x: CGFloat(x), y: CGFloat(y + size))
            c.context.scaleBy(x: 1, y: -1)
            c.context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
            c.context.restoreGState()
        } else {
            c.fill(x, y, size, size, mix(colors.normalBackground, colors.normal, 0.1))
            // A note, as in the Media Library.
            let nx = x + size / 2 - 2, ny = y + size / 2 - 4
            c.fill(nx + 3, ny, 1, 7, dim)
            c.fill(nx + 4, ny, 2, 1, dim)
            c.fill(nx, ny + 6, 4, 2, dim)
        }
        c.bevel(x, y, size, size, light: light, dark: dark)

        let textX = x + size + 6, room = parts.right - textX
        if let track = session.track {
            ListFont.draw(ListFont.truncate(track.title, toWidth: room), in: c, x: textX, y: y, color: colors.current)
            let byline = [track.artist, track.album].compactMap { $0 }.joined(separator: " - ")
            ListFont.draw(ListFont.truncate(byline, toWidth: room), in: c, x: textX, y: y + 11, color: colors.normal)
        } else {
            let line = session.phase == .idle ? "Nothing playing" : session.phase == .untagged ? "Untagged song" : ""
            ListFont.draw(line, in: c, x: textX, y: y, color: dim)
        }
        // The service, which opens the setup when clicked.
        let provider = pak.provider
        let service = "\(provider.name) / \(pak.model(of: provider))".uppercased()
        let rect = CGRect(x: textX, y: y + 24, width: PixelFont.width(of: service) + 2, height: 8)
        buttons.append((rect, .setUp))
        c.text(service, textX, y + 25, pressed == .button(.setUp) && pressedInside ? colors.current : dim)
    }

    private func drawBar(_ c: Canvas, _ parts: LinerNotesLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        let bar = parts.bar
        var x = Int(bar.minX)
        c.text("LOOK UP", x, Int(bar.minY) + 4, dim)
        x += PixelFont.width(of: "LOOK UP") + 5
        let current = pak.lookup
        for (lookup, label) in [(LinerNotesPak.Lookup.everyTrack, "AUTO"), (.whenAsked, "ASK"), (.off, "OFF")] {
            let rect = CGRect(x: x, y: Int(bar.minY), width: PixelFont.width(of: label) + 7, height: Int(bar.height))
            drawButton(c, label, rect, .lookup(lookup), selected: lookup == current, colors)
            x += Int(rect.width) + 2
        }
        let again = [.done, .looking].contains(session.phase) || { if case .failed = session.phase { return true }; return false }()
        if again, !showsSetup, session.track != nil {
            let label = "ASK AGAIN"
            let width = PixelFont.width(of: label) + 7
            let rect = CGRect(x: Int(bar.maxX) - width, y: Int(bar.minY), width: width, height: Int(bar.height))
            if Int(rect.minX) > x + 4 { drawButton(c, label, rect, .askAgain, selected: false, colors) }
        }
    }

    private func drawButton(_ c: Canvas, _ text: String, _ rect: CGRect, _ button: Button, selected: Bool, _ colors: PlaylistColors) {
        buttons.append((rect, button))
        let down = selected || (pressed == .button(button) && pressedInside)
        c.fill(rect, mix(colors.normalBackground, colors.normal, down ? 0.4 : 0.15))
        let light = mix(colors.normalBackground, colors.normal, 0.5), dark = mix(colors.normalBackground, rgb(0), 0.5)
        c.bevel(Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height), light: down ? dark : light, dark: down ? light : dark)
        c.text(text, Int(rect.minX) + 4, Int(rect.minY) + (Int(rect.height) - 6) / 2,
               down ? colors.current : mix(colors.normal, colors.normalBackground, 0.2))
    }

    /// Draws what's under the header; returns its height.
    private func drawBody(_ c: Canvas, _ parts: LinerNotesLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor, top: Int) -> Int {
        let body = parts.body, x = parts.left, width = Int(body.width)
        let middle = Int(body.midY) - ListFont.lineHeight / 2
        var y = top

        func paragraph(_ text: String, _ color: CGColor) {
            for line in Self.wrap(text, width: width) {
                ListFont.draw(line, in: c, x: x, y: y, color: color)
                y += ListFont.lineHeight
            }
        }
        func centered(_ text: String, _ y: Int, _ color: CGColor) {
            let text = ListFont.truncate(text, toWidth: width)
            ListFont.draw(text, in: c, x: x + (width - ListFont.width(of: text)) / 2, y: y, color: color)
        }

        if !isInserted {
            paragraph("The Liner Notes Pak is ejected. Insert it in the Expansion Paks window to look songs up.", dim)
            return y - top
        }
        if showsSetup {
            return drawSetup(c, parts, colors, dim, top: top)
        }
        let service = pak.provider.name
        switch session.phase {
        case .idle, .reading:
            break
        case .untagged:
            paragraph("Nothing to look up: this song has no title or artist tags.", dim)
        case .needsSetup:
            break
        case .off:
            paragraph("Looking up is off. Choose AUTO to look up every song as it plays, or ASK to look songs up when you want.", dim)
        case .waiting:
            centered("Looking this song up in \(session.secondsUntilLookup) s...", middle - 6, colors.normal)
            centered("(skip now and nothing is sent)", middle + 6, dim)
        case .ready:
            let label = "TELL ME ABOUT THIS SONG"
            let w = PixelFont.width(of: label) + 9
            drawButton(c, label, CGRect(x: x + (width - w) / 2, y: middle - 12, width: w, height: 15), .ask, selected: false, colors)
            centered("Sends the title, artist and album to \(service).", middle + 8, dim)
        case .looking where session.notes.isEmpty:
            centered("Asking \(service)...", middle, colors.normal)
        case .looking, .done:
            for part in session.notes.text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !part.isEmpty {
                for line in Self.wrap(part, width: width) {
                    Self.drawMarked(line, in: c, x: x, y: y, color: colors.normal, marks: dim)
                    y += ListFont.lineHeight
                }
                y += 4
            }
            if session.phase == .looking, (frameCount / 15) % 2 == 0 {
                c.fill(x, y - 4 - 2, 4, 1, colors.current)
            }
            for (index, source) in session.notes.sources.enumerated() {
                let label = "[\(index + 1)] " + Self.sourceLabel(source)
                let text = ListFont.truncate(label, toWidth: width)
                let rect = CGRect(x: x, y: y, width: ListFont.width(of: text), height: ListFont.lineHeight)
                sourceRects.append((rect, source.url))
                let hot = pressed == .source(source.url) && pressedInside
                ListFont.draw(text, in: c, x: x, y: y, color: hot ? colors.current : dim)
                y += ListFont.lineHeight
            }
        case .failed(let message, let badKey):
            paragraph(message, colors.normal)
            if badKey {
                y += 4
                drawButton(c, "SET UP", CGRect(x: x, y: y, width: PixelFont.width(of: "SET UP") + 9, height: 13), .setUp, selected: false, colors)
                y += 13
            }
        }
        return y - top
    }

    private func drawSetup(_ c: Canvas, _ parts: LinerNotesLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor, top: Int) -> Int {
        let x = parts.left, width = Int(parts.body.width)
        var y = top
        for line in Self.wrap("Liner Notes looks up the song that's playing. It sends the title, artist and album, never the audio, to the service you pick, with your own key. Nothing goes to Bitamp.", width: width) {
            ListFont.draw(line, in: c, x: x, y: y, color: colors.normal)
            y += ListFont.lineHeight
        }
        y += 5
        let labelWidth = 44
        let provider = pak.providers.first { $0.name == draftProvider } ?? pak.provider
        if pak.providers.count > 1 {
            c.text("SERVICE", x, y + 4, dim)
            var bx = x + labelWidth
            for option in pak.providers {
                let label = option.name.uppercased()
                let rect = CGRect(x: bx, y: y, width: PixelFont.width(of: label) + 7, height: 13)
                drawButton(c, label, rect, .provider(option.name), selected: option.name == provider.name, colors)
                bx += Int(rect.width) + 2
            }
            y += 17
        }
        let model = draftModel.flatMap { provider.models.contains($0) ? $0 : nil } ?? pak.model(of: provider)
        c.text("MODEL", x, y + 4, dim)
        var bx = x + labelWidth
        for option in provider.models {
            let label = option.uppercased()
            let rect = CGRect(x: bx, y: y, width: PixelFont.width(of: label) + 7, height: 13)
            drawButton(c, label, rect, .model(option), selected: option == model, colors)
            bx += Int(rect.width) + 2
        }
        y += 15
        if let cost = provider.costs[model] {
            ListFont.draw(cost, in: c, x: x + labelWidth, y: y, color: dim)
            y += ListFont.lineHeight
        }
        y += 3
        c.text("API KEY", x, y + 4, dim)
        keyBox.placeholder = pak.key(for: provider) == nil ? "Paste your \(provider.name) API key" : "Saved (paste to replace)"
        keyBox.rect = CGRect(x: x + labelWidth, y: y, width: width - labelWidth, height: 13)
        y += 15
        ListFont.draw("Kept in your Keychain.", in: c, x: x + labelWidth, y: y, color: dim)
        y += ListFont.lineHeight + 4
        var sx = x + labelWidth
        drawButton(c, "SAVE", CGRect(x: sx, y: y, width: PixelFont.width(of: "SAVE") + 9, height: 13), .save, selected: false, colors)
        sx += PixelFont.width(of: "SAVE") + 11
        if pak.key(for: pak.provider) != nil {
            drawButton(c, "CANCEL", CGRect(x: sx, y: y, width: PixelFont.width(of: "CANCEL") + 9, height: 13), .cancel, selected: false, colors)
        }
        y += 13
        return y - top
    }

    static func sourceLabel(_ source: LinerNotesSource) -> String {
        let host = source.url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        return host.isEmpty ? source.title : "\(source.title) - \(host)"
    }

    /// Lines of at most `width` pixels, broken between words. A citation mark ("[2]") stays
    /// on the line of the word before it.
    static func wrap(_ text: String, width: Int) -> [String] {
        var words: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if word.hasPrefix("["), let last = words.last { words[words.count - 1] = last + " " + word } else { words.append(word) }
        }
        var lines: [String] = [], line = ""
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            if ListFont.width(of: candidate) > width, !line.isEmpty {
                lines.append(line)
                line = word
            } else {
                line = candidate
            }
            // A word longer than the line, such as a long web address, is cut.
            while ListFont.width(of: line) > width, line.count > 1 {
                let cut = ListFont.truncate(line, toWidth: width)
                lines.append(cut)
                line = ""
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Draws a line with its "[n]" marks dimmed.
    static func drawMarked(_ line: String, in c: Canvas, x: Int, y: Int, color: CGColor, marks: CGColor) {
        var x = x
        for (index, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { x += ListFont.spaceWidth }
            let isMark = word.hasPrefix("[") && word.hasSuffix("]")
            x = ListFont.draw(String(word), in: c, x: x, y: y, color: isMark ? marks : color)
        }
    }

    // MARK: - Mouse

    private func press(at point: CGPoint) -> Press? {
        let parts = self.parts
        if PanelFrame(skin: skin, size: pixelSize, title: "LINER NOTES", active: isActive).close.contains(point) { return .close }
        if parts.grip.contains(point) { return .grip(startSize: .zero, startMouse: .zero) }
        if CGFloat(contentHeight) > parts.body.height, parts.scrollTrack.contains(point) { return .thumb(grab: 0) }
        if keyBox.rect != .zero, keyBox.rect.contains(point) { return .key }
        if let button = buttons.last(where: { $0.0.contains(point) && (!parts.body.contains($0.0.origin) || parts.body.contains(point)) }) {
            return .button(button.1)
        }
        if parts.body.contains(point), let source = sourceRects.first(where: { $0.0.contains(point) }) { return .source(source.1) }
        return nil
    }

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let press = press(at: point) else {
            window?.makeFirstResponder(self)
            return false
        }
        switch press {
        case .key:
            _ = keyBox.mouseDown(at: point, event: event)
            pressed = .key
        case .grip:
            pressed = .grip(startSize: window?.frame.size ?? frame.size, startMouse: NSEvent.mouseLocation)
        case .thumb:
            let thumb = thumbRect
            if thumb.contains(point) {
                pressed = .thumb(grab: point.y - thumb.minY)
            } else {
                scroll += point.y < thumb.minY ? -parts.body.height : parts.body.height
            }
        default:
            pressed = press
            pressedInside = true
        }
        needsDisplay = true
        return true
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        switch pressed {
        case .key?:
            keyBox.mouseDragged(to: point)
        case .grip(let startSize, let startMouse)?:
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            let proposed = CGSize(width: (startSize.width + mouse.x - startMouse.x) / scale,
                                  height: (startSize.height - (mouse.y - startMouse.y)) / scale)
            let pixels = normalizedPixelSize(proposed)
            let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
            guard size != window.frame.size else { return }
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height),
                            display: true)
        case .thumb(let grab)?:
            let track = parts.scrollTrack
            let travel = track.height - PlaylistLayout.scrollThumb.height
            let t = travel > 0 ? min(max((point.y - grab - track.minY) / travel, 0), 1) : 0
            scroll = t * max(0, CGFloat(contentHeight) - parts.body.height)
        case let press?:
            let inside = self.press(at: point) == press
            if inside != pressedInside {
                pressedInside = inside
                needsDisplay = true
            }
        case nil:
            break
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            pressed = nil
            pressedInside = false
            needsDisplay = true
        }
        switch pressed {
        case .key?:
            keyBox.mouseUp()
        case .close? where pressedInside:
            windowGroup?.setVisible(.linerNotes, false)
        case .source(let url)? where pressedInside:
            NSWorkspace.shared.open(url)
        case .button(let button)? where pressedInside:
            click(button)
        default:
            break
        }
    }

    private func click(_ button: Button) {
        switch button {
        case .lookup(let lookup):
            pak.lookup = lookup
            settingsChanged()
        case .askAgain, .ask:
            scroll = 0
            session.lookUp()
        case .setUp:
            settingUp = true
            draftProvider = nil
            draftModel = nil
            scroll = 0
            keyBox.focus()
        case .provider(let name):
            draftProvider = name
            draftModel = nil
        case .model(let name):
            draftModel = name
        case .save:
            saveSetup()
        case .cancel:
            endSetup()
        }
    }

    private func saveSetup() {
        let provider = pak.providers.first { $0.name == draftProvider } ?? pak.provider
        var changes = ["service": provider.name]
        if let draftModel, provider.models.contains(draftModel) { changes["\(provider.name.lowercased())-model"] = draftModel }
        let key = keyBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { changes["\(provider.name.lowercased())-key"] = key }
        guard !key.isEmpty || pak.key(for: provider) != nil else {
            flashMessage?("PASTE AN API KEY FIRST")
            keyBox.focus()
            return
        }
        pak.save(changes)
        endSetup()
    }

    private func endSetup() {
        keyBox.text = ""
        settingUp = false
        draftProvider = nil
        draftModel = nil
        window?.makeFirstResponder(self)
        settingsChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        let pixels = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / scale : event.scrollingDeltaY * CGFloat(ListFont.lineHeight) * 3
        scroll -= pixels
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, settingUp {  // Escape
            endSetup()
        } else if let keyFallback {
            keyFallback.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}
