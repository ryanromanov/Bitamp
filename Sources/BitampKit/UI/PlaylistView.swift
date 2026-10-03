import AppKit
import UniformTypeIdentifiers

/// The playlist window: the play queue as an editable list.
///
/// The frame is skin pixels like the other windows, but track names are drawn with a real
/// font at full resolution, so any title is readable, including non-Latin ones.
final class PlaylistView: SkinnedView {

    let controller: PlaybackController
    let preferences: Preferences
    /// Gets keys the playlist doesn't use, such as the transport letters.
    weak var keyFallback: NSResponder?

    private(set) var selection = IndexSet()
    /// The fixed end of a Shift-selection, and the end the arrow keys move.
    private var anchor: Int?
    private var focus: Int?
    private var scrollRow = 0
    private var scrollAccumulator: CGFloat = 0
    private var lastPlayingIndex: Int?
    private var closePressed = false
    private var shadePressed = false
    /// Where dropped files would go, as an insertion index, while a drag is over the list.
    private var dropIndex: Int?

    private enum Drag {
        /// Moving the selected rows. `clicked` collapses the selection to it if nothing moved.
        case rows(lastRow: Int, clicked: Int, moved: Bool)
        case scrollThumb(grab: CGFloat)
        case resize(startHeight: CGFloat, startMouseY: CGFloat)
        case close
        case shade
    }
    private var drag: Drag?

    init(controller: PlaybackController, preferences: Preferences, skin: Skin) {
        self.controller = controller
        self.preferences = preferences
        super.init(
            pixelSize: CGSize(width: PlaylistLayout.width, height: PlaylistLayout.defaultHeight),
            skin: skin, scale: CGFloat(preferences.scale))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        CGSize(width: PlaylistLayout.width,
               height: isShaded ? ShadeLayout.height : PlaylistLayout.snappedHeight(proposed.height))
    }

    private var queue: PlayQueue { controller.queue }
    /// 11 points at the normal 2× size, scaled with the window.
    private var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 5.5 * scale, weight: .regular) }
    private var listRect: CGRect { PlaylistLayout.list(in: pixelSize) }
    private var visibleRows: Int { max(1, Int(listRect.height / PlaylistLayout.rowHeight)) }
    private var maxScrollRow: Int { max(0, queue.count - visibleRows) }

    override func tick() {
        selection = selection.filteredIndexSet { $0 < queue.count }
        scrollRow = min(max(scrollRow, 0), maxScrollRow)
        // Follow the playing track when it changes.
        let playing = queue.playingIndex
        if playing != lastPlayingIndex, let playing { scrollToShow(playing) }
        lastPlayingIndex = playing
    }

    private func scrollToShow(_ row: Int) {
        if row < scrollRow {
            scrollRow = row
        } else if row >= scrollRow + visibleRows {
            scrollRow = row - visibleRows + 1
        }
        scrollRow = min(max(scrollRow, 0), maxScrollRow)
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        if isShaded {
            renderShade(c)
            return
        }
        let size = pixelSize
        let (w, h) = (Int(size.width), Int(size.height))
        let top = Int(PlaylistLayout.top), bottom = Int(PlaylistLayout.bottom)

        for x in stride(from: 25, to: w - 25, by: 25) {
            c.draw(skin.image(for: .playlistTopTile(active: isActive)), x, 0)
        }
        c.draw(skin.image(for: .playlistTitle(active: isActive)), (w - 100) / 2, 0)
        c.draw(skin.image(for: .playlistTopLeft(active: isActive)), 0, 0)
        c.draw(skin.image(for: .playlistTopRight(active: isActive)), w - 25, 0)
        for y in stride(from: top, to: h - bottom, by: Int(PlaylistLayout.heightStep)) {
            c.draw(skin.image(for: .playlistLeftTile), 0, y)
            c.draw(skin.image(for: .playlistRightTile), w - Int(PlaylistLayout.right), y)
        }
        for x in stride(from: 125, to: w - 150, by: 25) {
            c.draw(skin.image(for: .playlistBottomTile), x, h - bottom)
        }
        c.draw(skin.image(for: .playlistBottomLeft), 0, h - bottom)
        c.draw(skin.image(for: .playlistBottomRight), w - 150, h - bottom)
        c.draw(skin.image(for: .playlistShadeButton(pressed: shadePressed)),
               at: ShadeLayout.playlistShadeButton(width: size.width).origin)
        c.draw(skin.image(for: .playlistCloseButton(pressed: closePressed)), at: PlaylistLayout.close(in: size).origin)

        // The list: background, selection and drop marker. The text is drawn in drawOverlay.
        let colors = skin.playlistColors
        c.fill(listRect, colors.normalBackground)
        for row in visibleRange where selection.contains(row) {
            c.fill(rowRect(row), colors.selectedBackground)
        }
        if let dropIndex {
            let y = listRect.minY + CGFloat(dropIndex - scrollRow) * PlaylistLayout.rowHeight
            c.fill(CGRect(x: listRect.minX, y: min(y, listRect.maxY - 1), width: listRect.width, height: 1), colors.current)
        }

        let thumb = scrollThumbRect
        c.draw(skin.image(for: .playlistScrollThumb(pressed: isDraggingThumb)), at: thumb.origin)

        let runningTime = PlaylistLayout.runningTime(in: size)
        drawPixelText(c, runningTimeText, Int(runningTime.x), Int(runningTime.y))
        let miniTime = PlaylistLayout.miniTime(in: size)
        if controller.engine.state != .stopped {
            drawPixelText(c, TimeFormat.clock(controller.engine.currentTime), Int(miniTime.x), Int(miniTime.y))
        }
    }

    /// The strip shows the current track and its length.
    private func renderShade(_ c: Canvas) {
        let width = pixelSize.width
        let w = Int(width)
        for x in stride(from: 25, to: w - 50, by: 25) {
            c.draw(skin.image(for: .playlistShadeTile), x, 0)
        }
        c.draw(skin.image(for: .playlistShadeLeft(active: isActive)), 0, 0)
        c.draw(skin.image(for: .playlistShadeRight(active: isActive)), w - 50, 0)
        c.draw(skin.image(for: .playlistUnshadeButton(pressed: shadePressed)),
               at: ShadeLayout.playlistUnshade(width: width).origin)
        c.draw(skin.image(for: .playlistCloseButton(pressed: closePressed)),
               at: ShadeLayout.playlistClose(width: width).origin)

        guard let index = queue.playingIndex ?? queue.currentIndex else { return }
        let url = queue.items[index]
        let title = ShadeLayout.playlistTitle(width: width)
        c.context.saveGState()
        c.context.clip(to: title)
        drawPixelText(c, "\(index + 1). \(controller.info.displayName(for: url))", Int(title.minX), Int(title.minY))
        c.context.restoreGState()
        if let duration = controller.info.duration(for: url) {
            let time = ShadeLayout.playlistTime(width: width)
            let text = TimeFormat.clock(duration)
            // Right-aligned in the 20-pixel time box.
            drawPixelText(c, text, Int(time.x) + 20 - PixelFont.width(of: text), Int(time.y))
        }
    }

    private var visibleRange: Range<Int> {
        scrollRow..<min(queue.count, scrollRow + visibleRows)
    }

    private func rowRect(_ row: Int) -> CGRect {
        CGRect(
            x: listRect.minX, y: listRect.minY + CGFloat(row - scrollRow) * PlaylistLayout.rowHeight,
            width: listRect.width, height: PlaylistLayout.rowHeight)
    }

    private var isDraggingThumb: Bool {
        if case .scrollThumb = drag { return true }
        return false
    }

    private var scrollThumbRect: CGRect {
        let track = PlaylistLayout.scrollTrack(in: pixelSize)
        let travel = track.height - PlaylistLayout.scrollThumb.height
        let t = maxScrollRow == 0 ? 0 : CGFloat(scrollRow) / CGFloat(maxScrollRow)
        return CGRect(origin: CGPoint(x: track.minX, y: track.minY + (travel * t).rounded()), size: PlaylistLayout.scrollThumb)
    }

    /// "selected/total"; a "+" means some durations haven't loaded yet.
    private var runningTimeText: String {
        var total = 0.0, selected = 0.0, complete = true
        for (index, url) in queue.items.enumerated() {
            guard let duration = controller.info.duration(for: url) else {
                complete = false
                continue
            }
            total += duration
            if selection.contains(index) { selected += duration }
        }
        return "\(TimeFormat.clock(selected))/\(TimeFormat.clock(total))\(complete ? "" : "+")"
    }

    override func drawOverlay(in context: CGContext) {
        guard !isShaded else { return }
        let colors = skin.playlistColors
        let list = viewRect(forPixels: listRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: list).addClip()
        let playing = queue.playingIndex
        for row in visibleRange {
            let url = queue.items[row]
            let color = NSColor(cgColor: row == playing ? colors.current : colors.normal) ?? .green
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let rect = viewRect(forPixels: rowRect(row)).insetBy(dx: 2 * scale, dy: 0)
            let textY = rect.minY + (rect.height - font.boundingRectForFont.height) / 2 + scale / 2

            var nameWidth = rect.width
            if let duration = controller.info.duration(for: url) {
                let time = NSAttributedString(string: TimeFormat.clock(duration), attributes: attributes)
                let timeWidth = time.size().width
                time.draw(at: NSPoint(x: rect.maxX - timeWidth, y: textY))
                nameWidth -= timeWidth + 4 * scale
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var nameAttributes = attributes
            nameAttributes[.paragraphStyle] = style
            let name = NSAttributedString(string: "\(row + 1). \(controller.info.displayName(for: url))", attributes: nameAttributes)
            name.draw(with: NSRect(x: rect.minX, y: textY, width: max(0, nameWidth), height: rect.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Mouse

    private func row(at point: CGPoint) -> Int {
        scrollRow + Int(floor((point.y - listRect.minY) / PlaylistLayout.rowHeight))
    }

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        if isShaded {
            if ShadeLayout.playlistUnshade(width: pixelSize.width).contains(point) {
                drag = .shade
                shadePressed = true
            } else if ShadeLayout.playlistClose(width: pixelSize.width).contains(point) {
                drag = .close
                closePressed = true
            } else if event.clickCount == 2 {
                windowGroup?.toggleShade(.playlist)
            } else {
                return false
            }
            return true
        }
        guard let control = PlaylistLayout.control(at: point, in: pixelSize), control != .titleBar else {
            if event.clickCount == 2 && PlaylistLayout.titleBar(in: pixelSize).contains(point) {
                windowGroup?.toggleShade(.playlist)
                return true
            }
            return false
        }
        switch control {
        case .close:
            drag = .close
            closePressed = true
        case .shade:
            drag = .shade
            shadePressed = true
        case .list:
            listMouseDown(row: row(at: point), event: event)
        case .scrollbar:
            let thumb = scrollThumbRect
            if thumb.contains(point) {
                drag = .scrollThumb(grab: point.y - thumb.minY)
            } else {
                scrollRow += point.y < thumb.minY ? -visibleRows : visibleRows
                scrollRow = min(max(scrollRow, 0), maxScrollRow)
            }
        case .button(let button):
            let rect = viewRect(forPixels: PlaylistLayout.rect(button, in: pixelSize))
            menu(for: button).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: self)
        case .transport(let button):
            transport(button)
        case .resizeGrip:
            drag = .resize(startHeight: window?.frame.height ?? frame.height, startMouseY: NSEvent.mouseLocation.y)
        case .titleBar:
            return false
        }
        return true
    }

    private func listMouseDown(row: Int, event: NSEvent) {
        guard row < queue.count else {
            selection = []
            return
        }
        if event.clickCount == 2 {
            controller.playItem(at: row)
            return
        }
        let modifiers = event.modifierFlags
        focus = row
        if modifiers.contains(.command) {
            if selection.contains(row) { selection.remove(row) } else { selection.insert(row) }
            anchor = row
        } else if modifiers.contains(.shift), let anchor {
            selection = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
        } else {
            if !selection.contains(row) { selection = [row] }
            anchor = row
            drag = .rows(lastRow: row, clicked: row, moved: false)
        }
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        switch drag {
        case .rows(let lastRow, let clicked, let moved):
            // Dragging past the top or bottom of the list scrolls it.
            if point.y < listRect.minY { scrollRow = max(0, scrollRow - 1) }
            if point.y >= listRect.maxY { scrollRow = min(maxScrollRow, scrollRow + 1) }
            let target = min(max(row(at: point), 0), queue.count - 1)
            guard target != lastRow, let first = selection.first else { return }
            let newSelection = controller.move(selection, by: target - lastRow)
            let shift = (newSelection.first ?? first) - first
            selection = newSelection
            anchor = anchor.map { $0 + shift }
            focus = focus.map { $0 + shift }
            drag = .rows(lastRow: lastRow + shift, clicked: clicked + shift, moved: moved || shift != 0)
        case .scrollThumb(let grab):
            let track = PlaylistLayout.scrollTrack(in: pixelSize)
            let travel = track.height - PlaylistLayout.scrollThumb.height
            let t = travel > 0 ? min(max((point.y - grab - track.minY) / travel, 0), 1) : 0
            scrollRow = Int((t * CGFloat(maxScrollRow)).rounded())
        case .resize(let startHeight, let startMouseY):
            guard let window else { return }
            let proposed = (startHeight + startMouseY - NSEvent.mouseLocation.y) / scale
            let height = PlaylistLayout.snappedHeight(proposed) * scale
            guard height != window.frame.height else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        case .close:
            let rect = isShaded ? ShadeLayout.playlistClose(width: pixelSize.width) : PlaylistLayout.close(in: pixelSize)
            closePressed = rect.contains(point)
        case .shade:
            let rect = isShaded
                ? ShadeLayout.playlistUnshade(width: pixelSize.width)
                : ShadeLayout.playlistShadeButton(width: pixelSize.width)
            shadePressed = rect.contains(point)
        case nil:
            break
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        switch drag {
        case .rows(_, let clicked, let moved) where !moved:
            selection = [clicked]
        case .close where closePressed:
            windowGroup?.setVisible(.playlist, false)
        case .shade where shadePressed:
            windowGroup?.toggleShade(.playlist)
        default:
            break
        }
        drag = nil
        closePressed = false
        shadePressed = false
    }

    override func scrollWheel(with event: NSEvent) {
        let rows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / (PlaylistLayout.rowHeight * scale) : event.scrollingDeltaY
        scrollAccumulator -= rows
        let whole = Int(scrollAccumulator.rounded(.towardZero))
        scrollAccumulator -= CGFloat(whole)
        scrollRow = min(max(scrollRow + whole, 0), maxScrollRow)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = pixel(for: event)
        guard listRect.contains(point) else { return Menus.context() }
        let row = row(at: point)
        if row < queue.count && !selection.contains(row) { selection = [row] }
        return menu([
            ("Play", #selector(playSelected(_:)), ""),
            nil,
            ("Remove Selected", #selector(removeSelected(_:)), ""),
            ("Crop Selection", #selector(cropSelection(_:)), ""),
            nil,
            ("Select All", #selector(selectAll(_:)), ""),
            ("Select None", #selector(selectNone(_:)), ""),
        ])
    }

    private func transport(_ button: TransportButton) {
        let action: Selector
        switch button {
        case .previous: action = #selector(MainView.previousTrack(_:))
        case .play: action = #selector(MainView.play(_:))
        case .pause: action = #selector(MainView.pause(_:))
        case .stop: action = #selector(MainView.stop(_:))
        case .next: action = #selector(MainView.nextTrack(_:))
        case .eject: action = #selector(MainView.openFiles(_:))
        }
        NSApp.sendAction(action, to: nil, from: self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: moveFocus(by: -1, extend: extend)
        case .downArrow?: moveFocus(by: 1, extend: extend)
        case .pageUp?: moveFocus(by: -visibleRows, extend: extend)
        case .pageDown?: moveFocus(by: visibleRows, extend: extend)
        case .home?: moveFocus(by: -queue.count, extend: extend)
        case .end?: moveFocus(by: queue.count, extend: extend)
        case .carriageReturn?, .enter?: playSelected(nil)
        case .delete?, .deleteForward?: removeSelected(nil)
        default:
            if let keyFallback { keyFallback.keyDown(with: event) } else { super.keyDown(with: event) }
        }
    }

    private func moveFocus(by offset: Int, extend: Bool) {
        guard queue.count > 0 else { return }
        let from = focus ?? (offset > 0 ? -1 : queue.count)
        let to = min(max(from + offset, 0), queue.count - 1)
        if extend {
            let start = anchor ?? to
            selection = IndexSet(integersIn: min(start, to)...max(start, to))
            anchor = start
        } else {
            selection = [to]
            anchor = to
        }
        focus = to
        scrollToShow(to)
    }

    // MARK: - Button menus

    private func menu(for button: PlaylistLayout.Button) -> NSMenu {
        switch button {
        case .add:
            return menu([("Add Files…", #selector(addFiles(_:)), ""), ("Add Folder…", #selector(addFolder(_:)), "")])
        case .remove:
            return menu([
                ("Remove Selected", #selector(removeSelected(_:)), ""),
                ("Crop Selection", #selector(cropSelection(_:)), ""),
                ("Remove Missing Files", #selector(removeMissing(_:)), ""),
                nil,
                ("Clear Playlist", #selector(clearPlaylist(_:)), ""),
            ])
        case .select:
            return menu([
                ("Select All", #selector(selectAll(_:)), ""),
                ("Select None", #selector(selectNone(_:)), ""),
                ("Invert Selection", #selector(invertSelection(_:)), ""),
            ])
        case .misc:
            return menu([
                ("Sort by Title", #selector(sortByTitle(_:)), ""),
                ("Sort by File Name", #selector(sortByFileName(_:)), ""),
                ("Sort by Path", #selector(sortByPath(_:)), ""),
                nil,
                ("Reverse List", #selector(reverseList(_:)), ""),
                ("Randomize List", #selector(randomizeList(_:)), ""),
            ])
        case .list:
            return menu([
                ("New Playlist", #selector(clearPlaylist(_:)), ""),
                ("Open Playlist…", #selector(openPlaylist(_:)), ""),
                ("Save Playlist…", #selector(savePlaylist(_:)), ""),
            ])
        }
    }

    /// A menu of items targeting this view; nil is a separator.
    private func menu(_ items: [(String, Selector, String)?]) -> NSMenu {
        let menu = NSMenu()
        for entry in items {
            guard let (title, action, key) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Actions

    @objc func playSelected(_ sender: Any?) {
        guard let row = selection.first else { return }
        controller.playItem(at: row)
    }

    @objc func removeSelected(_ sender: Any?) {
        controller.remove(selection)
        selection = []
    }

    @objc func cropSelection(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        controller.crop(to: selection)
        selection = IndexSet(integersIn: 0..<queue.count)
    }

    @objc func removeMissing(_ sender: Any?) {
        controller.removeMissingFiles()
        selection = []
    }

    @objc func clearPlaylist(_ sender: Any?) {
        controller.removeAll()
        selection = []
    }

    @objc override func selectAll(_ sender: Any?) {
        selection = IndexSet(integersIn: 0..<queue.count)
    }

    @objc func selectNone(_ sender: Any?) {
        selection = []
    }

    @objc func invertSelection(_ sender: Any?) {
        selection = IndexSet(integersIn: 0..<queue.count).subtracting(selection)
    }

    @objc func sortByTitle(_ sender: Any?) { rearranged { controller.sort(by: .title) } }
    @objc func sortByFileName(_ sender: Any?) { rearranged { controller.sort(by: .fileName) } }
    @objc func sortByPath(_ sender: Any?) { rearranged { controller.sort(by: .path) } }
    @objc func reverseList(_ sender: Any?) { rearranged { controller.reverse() } }
    @objc func randomizeList(_ sender: Any?) { rearranged { controller.randomize() } }

    private func rearranged(_ change: () -> Void) {
        change()
        selection = []
        scrollRow = 0
    }

    @objc func addFiles(_ sender: Any?) {
        runOpenPanel(folders: false) { self.controller.insert($0, at: self.queue.count) }
    }

    @objc func addFolder(_ sender: Any?) {
        runOpenPanel(folders: true) { self.controller.insert($0, at: self.queue.count) }
    }

    @objc func openPlaylist(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.loadPlaylist(url)
        selection = []
        scrollRow = 0
    }

    @objc func savePlaylist(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8")].compactMap { $0 }
        panel.nameFieldStringValue = "Playlist.m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.savePlaylist(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func runOpenPanel(folders: Bool, then handle: ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        if !folders { panel.allowedContentTypes = [.audio] }
        guard panel.runModal() == .OK else { return }
        handle(panel.urls)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let pixelY = (bounds.height - point.y) / scale
        let row = scrollRow + Int(((pixelY - listRect.minY) / PlaylistLayout.rowHeight).rounded())
        dropIndex = min(max(row, scrollRow), min(queue.count, scrollRow + visibleRows))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        controller.insert(urls, at: dropIndex ?? queue.count)
        dropIndex = nil
        return true
    }
}
