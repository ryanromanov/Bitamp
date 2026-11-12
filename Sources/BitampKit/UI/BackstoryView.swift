import AppKit

/// Where things sit in the Backstory window, in skin pixels.
enum BackstoryLayout {
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

/// The Backstory window: the song that's playing, and notes about it with numbered
/// sources, from the Backstory Pak. Along the bottom, when to look songs up (AUTO, ASK,
/// OFF); the setup (service, model, key) shows in the window when there's no key yet, or
/// when the service line under the title is clicked.
///
/// A third-party notes Pak gets a window of its own just like it, named after the Pak.
/// Its SETTINGS button opens the Pak's settings form instead.
final class BackstoryView: SkinnedView {
    /// What VoiceOver calls the window.
    override var accessibilityName: String { session.pak.name }

    let session: BackstorySession
    let paks: PakRegistry
    /// The window this view is in, for its close button.
    let panel: WindowGroup.Panel
    /// Opens a third-party Pak's settings form.
    var onSettings: (() -> Void)?
    private var pak: NotesPak { session.pak }
    /// Backstory itself, whose setup is in the window; nil for a third-party notes Pak.
    private var backstory: BackstoryPak? { session.pak as? BackstoryPak }
    /// Gets keys the window doesn't use, such as the transport letters.
    weak var keyFallback: NSResponder?

    private var keyBox: PixelTextBox!
    /// Showing the setup though there's a key, to change it.
    private var settingUp = false
    /// The setup's choices before they're saved.
    private var draftProvider: String?
    private var draftModel: String?
    private var draftWikipedia: Bool?

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
        case lookup(NotesLookup), askAgain, ask, setUp, settings, model(String), service(String), back, early, wikipedia(Bool), save, cancel
    }

    private enum Press: Equatable {
        case close, grip(startSize: CGSize, startMouse: NSPoint), thumb(grab: CGFloat), key, button(Button), source(URL)
    }
    private var pressed: Press?
    private var pressedInside = false

    init(session: BackstorySession, paks: PakRegistry, skin: Skin, scale: CGFloat, panel: WindowGroup.Panel = .backstory) {
        self.session = session
        self.paks = paks
        self.panel = panel
        super.init(pixelSize: BackstoryLayout.defaultSize, skin: skin, scale: scale)
        keyBox = PixelTextBox(in: self, rect: .zero, placeholder: "Paste your API key", secure: true)
        keyBox.onSubmit = { [weak self] _ in self?.saveSetup() }
        session.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        BackstoryLayout.snapped(proposed)
    }

    /// Redraws every frame only while something moves: the countdown, notes arriving, or
    /// the key box's caret.
    override var redrawsEveryFrame: Bool {
        keyBox?.isEditing == true || session.phase == .looking || session.phase == .waiting
    }

    private var parts: BackstoryLayout.Parts {
        BackstoryLayout.Parts(size: pixelSize, gen: skin.gen != nil)
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

    private var showsSetup: Bool { settingUp || (backstory != nil && session.phase == .needsSetup) }

    private var title: String { pak.name.uppercased() }

    /// Whether the Pak has a settings form to open (Backstory's setup is in the window).
    private var hasSettings: Bool {
        backstory != nil || (pak as? ConfigurablePak)?.hasSettings == true
    }

    /// Who a lookup asks, for the window's words: "Claude", or "the Demo Notes Pak".
    private var serviceName: String {
        if usesOnDevice { return "the on-device model" }
        return backstory?.provider.name ?? "the \(pak.name) Pak"
    }

    /// A third-party Pak's line under the title: what it said it's connected to, or its name.
    private var pakLine: String {
        if case .connected(let name?) = pak.account, !name.isEmpty { return name }
        return "\(pak.name) Pak"
    }

    private var ejectedText: String {
        "The \(pak.name) Pak is ejected. Insert it in the Expansion Paks window to look songs up."
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        let parts = self.parts
        let colors = skin.playlistColors
        let dim = mix(colors.normal, colors.normalBackground, 0.45)
        let rule = mix(colors.normalBackground, colors.normal, 0.25)
        buttons = []
        sourceRects = []
        PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive)
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

    private func drawHeader(_ c: Canvas, _ parts: BackstoryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        let x = parts.left, y = Int(parts.header.minY), size = BackstoryLayout.cover
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
        // The service, which opens the setup when clicked. The on-device model is always
        // marked, since it knows less.
        let hot = pressed == .button(.setUp) && pressedInside
        if usesOnDevice {
            let label = "ON-DEVICE MODEL"
            Self.drawChip(c, textX, y + 24, colors.current)
            c.text(label, textX + 10, y + 25, colors.current)
            buttons.append((CGRect(x: textX, y: y + 24, width: PixelFont.width(of: label) + 12, height: 8), .setUp))
        } else {
            let service = backstory.map { "\($0.provider.name) / \($0.model(of: $0.provider))" } ?? pakLine
            let label = ListFont.truncate(service.uppercased(), toWidth: room - 50)
            if hasSettings {
                buttons.append((CGRect(x: textX, y: y + 24, width: PixelFont.width(of: label) + 2, height: 8), .setUp))
            }
            c.text(label, textX, y + 25, hot ? colors.current : dim)
        }
        // The setup, where anyone can see it; the service's name opens it too.
        guard hasSettings else { return }
        let label = "SETTINGS"
        let width = PixelFont.width(of: label) + 7
        drawButton(c, label, CGRect(x: parts.right - width, y: y + 21, width: width, height: 12), .settings,
                   selected: showsSetup, colors)
    }

    private func drawBar(_ c: Canvas, _ parts: BackstoryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        let bar = parts.bar
        var x = Int(bar.minX)
        c.text("LOOK UP", x, Int(bar.minY) + 4, dim)
        x += PixelFont.width(of: "LOOK UP") + 5
        let current = pak.lookup
        for (lookup, label) in [(NotesLookup.everyTrack, "AUTO"), (.whenAsked, "ASK"), (.off, "OFF")] {
            let rect = CGRect(x: x, y: Int(bar.minY), width: PixelFont.width(of: label) + 7, height: Int(bar.height))
            drawButton(c, label, rect, .lookup(lookup), selected: lookup == current, colors)
            x += Int(rect.width) + 2
        }
        // Readying the next song early only applies to AUTO, so it sits beside it.
        if current == .everyTrack {
            let label = "+ NEXT EARLY"
            x += 4
            let rect = CGRect(x: x, y: Int(bar.minY), width: PixelFont.width(of: label) + 7, height: Int(bar.height))
            drawButton(c, label, rect, .early, selected: pak.prefetch, colors)
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
    private func drawBody(_ c: Canvas, _ parts: BackstoryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor, top: Int) -> Int {
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

        // The setup works while ejected too, as the cartridge's Settings… opens it.
        if !isInserted, !settingUp {
            paragraph(ejectedText, dim)
            return y - top
        }
        if showsSetup {
            return drawSetup(c, parts, colors, dim, top: top)
        }
        let service = serviceName
        switch session.phase {
        case .idle, .reading:
            break
        case .untagged:
            paragraph("Nothing to look up: this song has no title or artist tags.", dim)
        case .needsSetup:
            // Backstory shows its setup instead.
            paragraph(needsSetupText, colors.normal)
            if hasSettings {
                y += 4
                drawButton(c, "SET UP", CGRect(x: x, y: y, width: PixelFont.width(of: "SET UP") + 9, height: 13), .setUp, selected: false, colors)
                y += 13
            }
        case .off:
            paragraph("Looking up is off. Choose AUTO to look up every song as it plays, or ASK to look songs up when you want.", dim)
        case .waiting:
            centered("Looking this song up in \(session.secondsUntilLookup) s...", middle - 6, colors.normal)
            if !usesOnDevice || backstory?.usesWikipedia == true { centered("(skip now and nothing is sent)", middle + 6, dim) }
        case .ready:
            let label = "TELL ME ABOUT THIS SONG"
            let w = PixelFont.width(of: label) + 9
            drawButton(c, label, CGRect(x: x + (width - w) / 2, y: middle - 12, width: w, height: 15), .ask, selected: false, colors)
            centered(readyLine, middle + 8, dim)
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
            if let caveat = onDeviceCaveat { paragraph(caveat, dim) }
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

    /// The setup, in two steps: where the notes come from, then that service's options.
    private func drawSetup(_ c: Canvas, _ parts: BackstoryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor, top: Int) -> Int {
        guard let pak = backstory else { return 0 }
        let x = parts.left, width = Int(parts.body.width)
        var y = top
        func paragraph(_ text: String, _ color: CGColor, indent: Int = 0) {
            for line in Self.wrap(text, width: width - indent) {
                ListFont.draw(line, in: c, x: x + indent, y: y, color: color)
                y += ListFont.lineHeight
            }
        }
        guard let page = draftProvider else {
            // Step 1: the services, one card each.
            paragraph(Self.chooseTitle, colors.normal)
            y += 4
            for service in pak.services {
                y = drawCard(c, service, x: x, y: y, width: width, colors, dim) + 3
            }
            if let footer = chooseFooter { paragraph(footer, dim) }
            if pak.choice() != nil {
                y += 4
                drawButton(c, "CANCEL", CGRect(x: x, y: y, width: PixelFont.width(of: "CANCEL") + 9, height: 13), .cancel, selected: false, colors)
                y += 13
            }
            return y - top
        }
        // Step 2: one service's options.
        let back = CGRect(x: x, y: y, width: PixelFont.width(of: "< BACK") + 9, height: 13)
        drawButton(c, "< BACK", back, .back, selected: false, colors)
        c.text(Self.pageTitle(page), Int(back.maxX) + 6, y + 4, colors.current)
        y += 19
        paragraph(pageText(page), dim)
        y += 6
        let labelWidth = 44
        if page == BackstoryPak.onDeviceName {
            let on = draftWikipedia ?? pak.usesWikipedia
            let label = (on ? "[X]" : "[ ]") + " LOOK UP FACTS ON WIKIPEDIA"
            drawButton(c, label, CGRect(x: x, y: y, width: PixelFont.width(of: label) + 9, height: 13), .wikipedia(!on), selected: on, colors)
            y += 16
            paragraph(Self.wikipediaNote, dim)
            y += 6
        } else if let provider = pak.providers.first(where: { $0.name == page }) {
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
            if let cost = provider.costs[model] { paragraph(cost, dim, indent: labelWidth) }
            y += 4
            c.text("KEY", x, y + 4, dim)
            keyBox.placeholder = pak.key(for: provider) == nil ? "Paste your \(provider.name) API key" : "Saved (paste to replace)"
            keyBox.rect = CGRect(x: x + labelWidth, y: y, width: width - labelWidth, height: 13)
            y += 15
            paragraph("Kept in your Keychain.", dim, indent: labelWidth)
            y += 6
        }
        drawButton(c, "SAVE", CGRect(x: x, y: y, width: PixelFont.width(of: "SAVE") + 9, height: 13), .save, selected: false, colors)
        return y + 13 - top
    }

    /// A service to choose: its name, and a line on what it gives and costs.
    private func drawCard(_ c: Canvas, _ service: String, x: Int, y: Int, width: Int, _ colors: PlaylistColors, _ dim: CGColor) -> Int {
        let rect = CGRect(x: x, y: y, width: width, height: 26)
        buttons.append((rect, .service(service)))
        let current = service == savedService
        let down = current || (pressed == .button(.service(service)) && pressedInside)
        c.fill(rect, mix(colors.normalBackground, colors.normal, down ? 0.3 : 0.1))
        let light = mix(colors.normalBackground, colors.normal, 0.5), dark = mix(colors.normalBackground, rgb(0), 0.5)
        c.bevel(x, y, width, 26, light: down ? dark : light, dark: down ? light : dark)
        if service == BackstoryPak.onDeviceName {
            Self.drawChip(c, x + 5, y + 3, current ? colors.current : colors.normal)
            c.text(service.uppercased(), x + 15, y + 4, current ? colors.current : colors.normal)
        } else {
            c.text(service.uppercased(), x + 5, y + 4, current ? colors.current : colors.normal)
        }
        ListFont.draw(ListFont.truncate(cardLine(service), toWidth: width - 16), in: c, x: x + 5, y: y + 13, color: current ? colors.normal : dim)
        c.text(">", x + width - 9, y + 10, current ? colors.current : dim)
        return y + 26
    }

    static let chooseTitle = "Where should notes come from?"

    /// Under the cards: who needs a key, and on older macOS, what a newer one adds.
    private var chooseFooter: String? {
        guard let pak = backstory else { return nil }
        guard pak.onDevice != nil else {
            return "Each uses your own key. On macOS 26 or later with Apple Intelligence, Backstory can also run free on this Mac."
        }
        let names = pak.providers.map(\.name)
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "\(names[0]) uses your own key." : names.dropLast().joined(separator: ", ") + " and \(names.last!) use your own key."
    }

    /// The line on a service's card.
    private func cardLine(_ service: String) -> String {
        guard let pak = backstory else { return "" }
        if service == BackstoryPak.onDeviceName {
            guard pak.onDevice?.isAvailable() == true else { return "Free, on this Mac. Needs Apple Intelligence." }
            return pak.usesWikipedia ? "Free, on this Mac, with facts from Wikipedia." : "Free, on this Mac. Knows less."
        }
        return pak.providers.first { $0.name == service }?.summary ?? "Notes with sources, from the web."
    }

    static func pageTitle(_ service: String) -> String {
        service == BackstoryPak.onDeviceName ? "ON-DEVICE MODEL" : service.uppercased()
    }

    /// What a service's page says first: what it is, and what it sends.
    private func pageText(_ service: String) -> String {
        guard let pak = backstory else { return "" }
        guard service == BackstoryPak.onDeviceName else {
            return "Looks the song up on the web, with sources. Sends the title, artist and album, never the audio, to \(service). Nothing goes to Bitamp."
        }
        guard pak.onDevice?.isAvailable() == true else {
            return "Not ready yet. Turn on Apple Intelligence in System Settings, and it works free once its model downloads."
        }
        return "Free, and written on this Mac. On its own it knows less than a service with web search, and cites nothing."
    }

    static let wikipediaNote = "Sends the title, artist and album to Wikipedia, and writes from the song's article. With no article, it writes from memory."

    /// The service saved now.
    private var savedService: String {
        guard let pak = backstory else { return "" }
        return pak.choosesOnDevice ? BackstoryPak.onDeviceName : pak.provider.name
    }

    /// The service the setup's second step shows, or else the one saved.
    private var selectedService: String {
        draftProvider ?? savedService
    }

    /// Whether lookups go to the on-device model: these notes came from it, or the next
    /// lookup will.
    private var usesOnDevice: Bool {
        session.phase == .done || session.phase == .looking ? session.notes.isOnDevice : pak.choice().map(\.onDevice) ?? (backstory?.choosesOnDevice == true)
    }

    /// Under TELL ME ABOUT THIS SONG: what a lookup sends, and where.
    private var readyLine: String {
        guard usesOnDevice else { return "Sends the title, artist and album to \(serviceName)." }
        return backstory?.usesWikipedia == true ? "Looks the song up on Wikipedia, and writes the notes on this Mac."
            : "Stays on this Mac, with Apple's on-device model."
    }

    /// What a third-party Pak's window says while it needs setting up.
    private var needsSetupText: String {
        hasSettings ? "The \(pak.name) Pak needs setting up first." : "The \(pak.name) Pak can't look songs up right now."
    }

    /// Under notes the on-device model wrote, which can be wrong.
    private var onDeviceCaveat: String? {
        guard session.notes.isOnDevice else { return nil }
        return session.notes.sources.isEmpty
            ? "No sources: the on-device model knows less, and can get details wrong."
            : "Written on this Mac by the on-device model from Wikipedia. It can still get details wrong."
    }

    /// A 7×7 chip: the on-device model's mark.
    static func drawChip(_ c: Canvas, _ x: Int, _ y: Int, _ color: CGColor) {
        c.fill(x + 1, y + 1, 5, 5, color)
        for i in [2, 4] {
            c.fill(x + i, y, 1, 1, color)
            c.fill(x + i, y + 6, 1, 1, color)
            c.fill(x, y + i, 1, 1, color)
            c.fill(x + 6, y + i, 1, 1, color)
        }
    }

    static func sourceLabel(_ source: BackstorySource) -> String {
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

    // MARK: - Accessibility

    /// What the notes area says now, for VoiceOver.
    private var bodyText: String? {
        if !isInserted { return ejectedText }
        let service = serviceName
        switch session.phase {
        case .idle: return "Nothing playing."
        case .reading: return nil
        case .needsSetup: return backstory == nil ? needsSetupText : nil
        case .untagged: return "Nothing to look up: this song has no title or artist tags."
        case .off: return "Looking up is off."
        case .waiting: return "Looking this song up in \(session.secondsUntilLookup) seconds."
        case .ready: return readyLine
        case .looking where session.notes.isEmpty: return "Asking \(service)."
        case .looking, .done:
            var text = session.notes.text.replacingOccurrences(of: "\n\n", with: "\n")
            if let caveat = onDeviceCaveat { text += "\n" + caveat }
            return text
        case .failed(let message, _): return message
        }
    }

    private func buttonControl(_ number: Int, _ rect: CGRect, _ button: Button) -> AccessibleControl {
        let kind: AccessibleControl.Kind, label: String
        switch button {
        case .lookup(let lookup):
            kind = .checkBox(lookup == pak.lookup)
            label = ["Every track": "Auto, look up every song", "When I ask": "Ask, look up when asked", "Off": "Off, don't look up"][lookup.rawValue] ?? lookup.rawValue
        case .askAgain: (kind, label) = (.button, "Ask Again")
        case .ask: (kind, label) = (.button, "Tell Me About This Song")
        case .setUp where rect.height <= 8:
            (kind, label) = (.button, usesOnDevice ? "Service: on-device model"
                : backstory.map { "Service: \($0.provider.name), \($0.model(of: $0.provider))" } ?? "Settings: \(pakLine)")
        case .setUp: (kind, label) = (.button, "Set Up")
        case .settings: (kind, label) = (.button, "\(pak.name) Settings")
        case .service(let name):
            (kind, label) = (.checkBox(name == savedService), "\(name == BackstoryPak.onDeviceName ? "On-device model" : name): \(cardLine(name))")
        case .back: (kind, label) = (.button, "Back to the services")
        case .early:
            (kind, label) = (.checkBox(pak.prefetch), usesOnDevice || backstory == nil ? "Get the next song's notes early" : "Get the next song's notes early. A skipped song still costs.")
        case .model(let name):
            let selected = selectedService
            let current = backstory.map { pak in draftModel ?? pak.model(of: pak.providers.first { $0.name == selected } ?? pak.provider) }
            (kind, label) = (.checkBox(name == current), "Model: \(name)")
        case .wikipedia:
            (kind, label) = (.checkBox(draftWikipedia ?? (backstory?.usesWikipedia == true)), "Look up facts on Wikipedia. " + Self.wikipediaNote)
        case .save: (kind, label) = (.button, "Save")
        case .cancel: (kind, label) = (.button, "Cancel")
        }
        return AccessibleControl(id: "button-\(number)", kind: kind, label: label, rect: rect,
                                 press: { [weak self] in
                                     self?.click(button)
                                     self?.needsDisplay = true
                                 })
    }

    /// Built from what the last frame drew: its buttons and source links.
    override func accessibleControls() -> [AccessibleControl] {
        let parts = self.parts
        var controls = [AccessibleControl(id: "close", kind: .button, label: "Close",
                                          rect: PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive).close,
                                          press: { [weak self] in self.map { $0.windowGroup?.setVisible($0.panel, false) } })]
        if let track = session.track {
            controls.append(AccessibleControl(id: "song", kind: .text,
                                              label: [track.title, track.artist, track.album].compactMap { $0 }.joined(separator: ", "),
                                              rect: CGRect(x: parts.header.minX + CGFloat(BackstoryLayout.cover) + 6, y: parts.header.minY,
                                                           width: parts.header.width - CGFloat(BackstoryLayout.cover) - 6, height: 22)))
        }
        if !showsSetup, let text = bodyText {
            // As tall as the words, so the sources under them come after.
            let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Self.wrap($1, width: Int(parts.body.width)).count) }
            let height = min(parts.body.height, CGFloat(lines * ListFont.lineHeight) - scroll)
            controls.append(AccessibleControl(id: "notes", kind: .text, label: text,
                                              rect: CGRect(x: parts.body.minX, y: parts.body.minY, width: parts.body.width, height: max(height, 8))))
        } else if showsSetup {
            controls.append(AccessibleControl(id: "about", kind: .text,
                                              label: draftProvider.map(pageText) ?? ([Self.chooseTitle, chooseFooter].compactMap { $0 }.joined(separator: " ")),
                                              rect: CGRect(x: parts.body.minX, y: parts.body.minY, width: parts.body.width, height: 20)))
        }
        for (number, (rect, button)) in buttons.enumerated() where rect.intersects(parts.content) {
            controls.append(buttonControl(number, rect, button))
        }
        for (number, (rect, url)) in sourceRects.enumerated() where rect.intersects(parts.body) {
            let label = session.notes.sources.first { $0.url == url }.map { "\(number + 1): \(Self.sourceLabel($0))" } ?? url.absoluteString
            controls.append(AccessibleControl(id: "source-\(number)", kind: .link, label: label, rect: rect,
                                              press: { NSWorkspace.shared.open(url) }))
        }
        return controls
    }

    // MARK: - Mouse

    private func press(at point: CGPoint) -> Press? {
        let parts = self.parts
        if PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive).close.contains(point) { return .close }
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
            windowGroup?.setVisible(panel, false)
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
        case .setUp where backstory == nil, .settings where backstory == nil:
            onSettings?()
        case .setUp:
            showSetup()
        case .settings:
            if settingUp { endSetup() } else { showSetup() }
        case .service(let name):
            openPage(name)
        case .back:
            draftProvider = nil
            draftModel = nil
            draftWikipedia = nil
            keyBox.text = ""
            window?.makeFirstResponder(self)
        case .early:
            pak.prefetch.toggle()
            if pak.prefetch, backstory != nil, !usesOnDevice { flashMessage?("A SKIPPED SONG STILL COSTS") }
            settingsChanged()
        case .model(let name):
            draftModel = name
        case .wikipedia(let on):
            draftWikipedia = on
        case .save:
            saveSetup()
        case .cancel:
            endSetup()
        }
    }

    /// Shows the setup: the services to choose from, or with `service`, that one's page.
    func showSetup(service: String? = nil) {
        guard backstory != nil else { return }
        settingUp = true
        draftProvider = nil
        draftModel = nil
        draftWikipedia = nil
        scroll = 0
        if let service { openPage(service) }
        needsDisplay = true
    }

    /// The setup's second step, for one service.
    private func openPage(_ service: String) {
        draftProvider = service
        draftModel = nil
        draftWikipedia = nil
        scroll = 0
        if service != BackstoryPak.onDeviceName { keyBox.focus() }
    }

    private func saveSetup() {
        guard let pak = backstory else { return }
        if selectedService == BackstoryPak.onDeviceName {
            var changes = ["service": BackstoryPak.onDeviceName]
            if let draftWikipedia { changes["wikipedia"] = draftWikipedia ? "On" : "Off" }
            pak.save(changes)
            endSetup()
            return
        }
        let provider = pak.providers.first { $0.name == selectedService } ?? pak.provider
        var changes = ["service": provider.name]
        if let draftModel, provider.models.contains(draftModel) { changes["\(provider.name.lowercased())-model"] = draftModel }
        let key = keyBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { changes["\(provider.name.lowercased())-key"] = key }
        // Without a key, the on-device model answers if there is one.
        guard !key.isEmpty || pak.key(for: provider) != nil || pak.onDeviceChoice() != nil else {
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
        draftWikipedia = nil
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
