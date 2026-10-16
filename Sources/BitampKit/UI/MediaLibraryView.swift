import AppKit

/// The Media Library: one Pak's music to browse, search, and play or add to the playlist.
///
/// On the left, a search box and the Pak's sections (`.root`); on the right, the open
/// page: an album or playlist's header, then shelves of songs as rows and albums, artists
/// and playlists as covers. Double-click opens a place or plays a song; Play and Add take
/// what's selected, or a whole album or playlist when nothing is. A Pak that doesn't
/// browse shows its search, starting with an empty one.
///
/// Everything is drawn in skin pixels in the frame the Expansion Paks window wears.
final class MediaLibraryView: SkinnedView, NSDraggingSource {
    /// What a drag from the library carries; the items themselves stay with the view.
    static let draggedItems = NSPasteboard.PasteboardType("com.ryanromanov.bitamp.library-items")

    let controller: PlaybackController
    /// Gets keys the library doesn't use, such as the transport letters.
    weak var keyFallback: NSResponder?

    private(set) var pak: Pak?
    private var search: PixelTextBox!

    /// The sidebar: group titles (no place) and sections.
    private(set) var sidebar: [(title: String, place: PakPlace?)] = []
    private var selectedSection: String?

    /// A page as shown: what the Pak gave so far, where it was scrolled.
    struct Shown {
        let location: PakLocation
        var title: String
        var header: PakHeader?
        var shelves: [PakShelf] = []
        var cursor: String?
        var scroll: CGFloat = 0

        var items: [PakItem] { shelves.flatMap(\.items) }
    }
    private(set) var shown: Shown?
    private var history: [Shown] = []
    private var items: [PakItem] = []
    private var blocks: [LibraryLayout.Block] = []
    private var contentHeight = 0
    private var laidOutWidth = 0
    private(set) var selection = IndexSet()
    private var anchor: Int?
    /// The item the arrow keys move from.
    private(set) var focus: Int?
    /// Each item's block and column, for moving up and down through rows of covers.
    private var positions: [(block: Int, column: Int)] = []
    /// How far the sidebar is scrolled, for a Pak with more sections than fit.
    private var sidebarScroll: CGFloat = 0
    /// A click on an item, until it becomes a drag or a click. `collapse` is a selected
    /// item that becomes the only selection if the mouse comes up without dragging.
    private var itemPress: (point: CGPoint, index: Int, collapse: Bool)?
    /// What's being dragged out, for `dropDragged(at:)`.
    private var dragged: [PakItem] = []
    /// What the pane says instead of a page: loading, an error, nothing there.
    private(set) var message: String?
    /// Bumped by every navigation, so answers about an earlier page are dropped.
    private var generation = 0
    private var loadingMore = false

    let covers: CoverCache
    private var coverTasks: [CoverCache.Key: Task<Void, Never>] = [:]
    /// The covers the last frame drew, so ones that scrolled away stop loading.
    private var wantedCovers: Set<CoverCache.Key> = []

    private enum Press: Equatable {
        case close, back, play, add, grip(startSize: CGSize, startMouse: NSPoint), thumb(grab: CGFloat), search, items
    }
    private var pressed: Press?
    private var pressedInside = false

    /// `covers` keeps them in memory only unless given a folder; Bitamp gives it one.
    init(controller: PlaybackController, skin: Skin, scale: CGFloat, covers: CoverCache = CoverCache()) {
        self.controller = controller
        self.covers = covers
        super.init(pixelSize: LibraryLayout.defaultSize, skin: skin, scale: scale)
        search = PixelTextBox(in: self, rect: parts.search, placeholder: "Search")
        search.onSubmit = { [weak self] term in self?.runSearch(term) }
        search.onTab = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
            if focus == nil { moveFocus(to: 0) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        LibraryLayout.snapped(proposed)
    }

    /// Nothing moves in the library but the search box's caret, so it redraws when it
    /// changes: loads, covers, scrolling, and the events `SkinnedView` redraws for.
    override var redrawsEveryFrame: Bool { search?.isEditing == true }

    private var keyObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        // The title bar shows whether the window has focus, and the caret stops blinking.
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: nil, using: redraw)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard search != nil else { return }
        search.rect = parts.search
        relayout()
    }

    override func skinDidChange() {
        super.skinDidChange()
        guard search != nil else { return }
        search.rect = parts.search
        relayout()
    }

    private var parts: LibraryLayout.Parts {
        LibraryLayout.Parts(size: pixelSize, gen: skin.gen != nil)
    }

    private var title: String {
        (pak?.name ?? "Media Library").uppercased()
    }

    // MARK: - Showing a Pak

    /// Shows `pak`'s music. The same Pak again keeps where it was.
    func show(_ pak: Pak) {
        guard pak !== self.pak || shown == nil else { return }
        clear()
        self.pak = pak
        search.placeholder = "Search \(pak.name)"
        if pak.canBrowse {
            loadSidebar()
        } else {
            open(.search(""), title: "All", pushing: false)
        }
    }

    /// Forgets the Pak and everything shown, stopping its loads: for when it's ejected.
    func clear() {
        generation += 1
        coverTasks.values.forEach { $0.cancel() }
        coverTasks = [:]
        pak = nil
        sidebar = []
        selectedSection = nil
        shown = nil
        history = []
        selection = []
        message = nil
        search.text = ""
        relayout()
    }

    private var canAsk: Bool {
        guard let pak else { return false }
        return pak.isAvailable && controller.paks.isInserted(pak)
    }

    private func loadSidebar() {
        guard let pak, canAsk else { return }
        generation += 1
        let generation = generation
        message = "Loading…"
        Task {
            do {
                let root = try await pak.browse(.root, after: nil)
                guard generation == self.generation else { return }
                sidebar = root.shelves.flatMap { shelf -> [(title: String, place: PakPlace?)] in
                    let sections = shelf.items.compactMap(\.place).map { (title: $0.title, place: Optional($0)) }
                    return shelf.title.map { [(title: $0, place: nil)] + sections } ?? sections
                }
                message = nil
                if let first = sidebar.lazy.compactMap(\.place).first { openSection(first) }
            } catch {
                guard generation == self.generation else { return }
                message = error.localizedDescription
            }
            needsDisplay = true
        }
    }

    private func openSection(_ place: PakPlace) {
        selectedSection = place.id
        history = []
        open(.place(place.id), title: place.title, pushing: false)
    }

    private func runSearch(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard pak?.canBrowse == false || !term.isEmpty else { return }
        selectedSection = nil
        history = []
        open(.search(term), title: term.isEmpty ? "All" : "Search: \(term)", pushing: false)
    }

    /// Opens `location`, keeping the page shown now for Back when `pushing`.
    private func open(_ location: PakLocation, title: String, pushing: Bool) {
        guard let pak, canAsk else { return }
        if pushing, var current = shown {
            current.scroll = scroll
            history.append(current)
        }
        generation += 1
        let generation = generation
        shown = Shown(location: location, title: title)
        selection = []
        focus = nil
        loadingMore = false
        message = "Loading…"
        relayout()
        Task {
            do {
                let page = try await pak.browse(location, after: nil)
                guard generation == self.generation else { return }
                shown?.header = page.header
                shown?.shelves = page.shelves
                shown?.cursor = page.cursor
                message = page.shelves.allSatisfy(\.items.isEmpty) ? "Nothing here." : nil
            } catch {
                guard generation == self.generation else { return }
                message = error.localizedDescription
            }
            relayout()
        }
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        generation += 1
        shown = previous
        selection = []
        focus = nil
        message = previous.items.isEmpty ? "Nothing here." : nil
        relayout()
        scroll = previous.scroll
    }

    /// Gets more of the last shelf, when the page has more and it's scrolled near the end.
    private func loadMoreIfNeeded() {
        guard let pak, canAsk, !loadingMore, let shown, let cursor = shown.cursor,
              scroll + parts.list.height > CGFloat(contentHeight) - 120 else { return }
        loadingMore = true
        let generation = generation
        Task {
            defer { if generation == self.generation { loadingMore = false } }
            guard let page = try? await pak.browse(shown.location, after: cursor), generation == self.generation else { return }
            // The new page's first shelf carries on the last one's.
            var shelves = self.shown?.shelves ?? []
            for (index, shelf) in page.shelves.enumerated() {
                if index == 0, let last = shelves.indices.last {
                    shelves[last].items += shelf.items
                } else {
                    shelves.append(shelf)
                }
            }
            self.shown?.shelves = shelves
            self.shown?.cursor = page.cursor
            relayout()
        }
    }

    // MARK: - Layout and scrolling

    private var scroll: CGFloat {
        get { shown?.scroll ?? 0 }
        set {
            let limit = max(0, CGFloat(contentHeight) - parts.list.height)
            shown?.scroll = min(max(newValue, 0), limit)
            needsDisplay = true
        }
    }

    private func relayout() {
        items = shown?.items ?? []
        let width = Int(parts.list.width)
        (blocks, contentHeight) = LibraryLayout.blocks(header: shown?.header != nil, shelves: shown?.shelves ?? [], width: width)
        laidOutWidth = width
        positions = Array(repeating: (0, 0), count: items.count)
        for (number, block) in blocks.enumerated() {
            switch block.kind {
            case .track(let index): positions[index] = (number, 0)
            case .grid(let indices): for (column, index) in indices.enumerated() { positions[index] = (number, column) }
            case .header, .shelfTitle: break
            }
        }
        selection = selection.filteredIndexSet { $0 < items.count }
        if let focus, focus >= items.count { self.focus = nil }
        scroll = scroll
        needsDisplay = true
    }

    private var isScrollable: Bool {
        CGFloat(contentHeight) > parts.list.height
    }

    private var thumbRect: CGRect {
        let track = parts.scrollTrack
        let travel = track.height - PlaylistLayout.scrollThumb.height
        let limit = max(1, CGFloat(contentHeight) - parts.list.height)
        return CGRect(origin: CGPoint(x: track.minX, y: track.minY + (travel * scroll / limit).rounded()), size: PlaylistLayout.scrollThumb)
    }

    override func tick() {
        guard window?.isVisible == true else { return }
        loadMoreIfNeeded()
        // Stop loading covers that scrolled away.
        for (key, task) in coverTasks where !wantedCovers.contains(key) {
            task.cancel()
            coverTasks[key] = nil
        }
    }

    // MARK: - Covers

    /// The cover for `artwork` at `size` pixels, if it's cached; asks for it if not.
    private func cover(_ artwork: PakArtwork?, size: Int) -> CGImage? {
        guard let artwork, let pak else { return nil }
        let key = CoverCache.Key(pak: pak.id, artwork: artwork, size: size)
        wantedCovers.insert(key)
        if let image = covers.cached(key) { return image }
        guard coverTasks[key] == nil, canAsk else { return nil }
        coverTasks[key] = Task { [weak self] in
            let image = await self?.covers.load(key, from: pak)
            guard let self, !Task.isCancelled else { return }
            coverTasks[key] = nil
            if image != nil { needsDisplay = true }
        }
        return nil
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        let parts = self.parts
        let colors = skin.playlistColors
        let dim = mix(colors.normal, colors.normalBackground, 0.45)
        PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive)
            .draw(c, closePressed: pressed == .close && pressedInside)
        c.fill(skin.gen == nil ? CGRect(x: parts.content.minX, y: parts.content.minY,
                                        width: parts.scrollTrack.minX - parts.content.minX, height: parts.content.height)
                               : parts.content, colors.normalBackground)

        search.draw(c, skin: skin, frameCount: frameCount)
        drawSidebar(c, parts, colors, dim)
        c.fill(parts.dividerX, Int(parts.content.minY) + 2, 1, Int(parts.content.height) - 4, dim)
        drawBar(c, parts, colors, dim)

        wantedCovers = []
        c.context.saveGState()
        c.context.clip(to: parts.list)
        let top = Int(parts.list.minY) - Int(scroll.rounded())
        let visible = Int(scroll)..<(Int(scroll) + Int(parts.list.height) + 1)
        for block in blocks where block.y + block.height > visible.lowerBound && block.y < visible.upperBound {
            draw(block, at: top + block.y, c, parts, colors, dim)
        }
        if let message {
            let width = ListFont.width(of: message)
            let y = items.isEmpty ? Int(parts.list.minY) + 24 : top + contentHeight + 4
            ListFont.draw(ListFont.truncate(message, toWidth: Int(parts.list.width) - 4), in: c,
                          x: Int(parts.list.minX) + max(2, (Int(parts.list.width) - width) / 2), y: y, color: dim)
        }
        c.context.restoreGState()
        if isScrollable {
            c.draw(skin.image(for: .playlistScrollThumb(pressed: isDraggingThumb)), at: thumbRect.origin)
        }
    }

    private var isDraggingThumb: Bool {
        if case .thumb? = pressed { return true }
        return false
    }

    private func drawSidebar(_ c: Canvas, _ parts: LibraryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        c.context.saveGState()
        c.context.clip(to: CGRect(x: parts.sidebar.minX, y: CGFloat(parts.sectionsTop), width: parts.sidebar.width,
                                  height: parts.sidebar.maxY - CGFloat(parts.sectionsTop)))
        var y = parts.sectionsTop - Int(sidebarScroll)
        for (index, entry) in sidebar.enumerated() {
            if entry.place == nil, index > 0 { y += 3 }
            let x = Int(parts.sidebar.minX) + 3
            if let place = entry.place {
                if place.id == selectedSection {
                    c.fill(Int(parts.sidebar.minX) + 1, y, Int(parts.sidebar.width) - 2, LibraryLayout.sidebarRow, colors.selectedBackground)
                }
                ListFont.draw(ListFont.truncate(entry.title, toWidth: Int(parts.sidebar.width) - 14), in: c, x: x + 8, y: y + 1, color: colors.normal)
            } else {
                // A little ▾ before a group's title.
                c.fill(x, y + 6, 3, 1, dim)
                c.fill(x + 1, y + 7, 1, 1, dim)
                ListFont.draw(ListFont.truncate(entry.title, toWidth: Int(parts.sidebar.width) - 10), in: c, x: x + 5, y: y + 1, color: colors.current)
            }
            y += LibraryLayout.sidebarRow
        }
        c.context.restoreGState()
    }

    /// Back, the page's title, and Play and Add at the right.
    private func drawBar(_ c: Canvas, _ parts: LibraryLayout.Parts, _ colors: PlaylistColors, _ dim: CGColor) {
        let bar = parts.bar
        var x = Int(bar.minX)
        if !history.isEmpty {
            ListFont.draw("< Back", in: c, x: x, y: Int(bar.minY) + 2, color: pressed == .back && pressedInside ? colors.current : dim)
            x += ListFont.width(of: "< Back") + 8
        }
        let (play, add) = buttonRects(parts)
        if let shown {
            ListFont.draw(ListFont.truncate(shown.title, toWidth: Int(play.minX) - x - 6), in: c, x: x, y: Int(bar.minY) + 2,
                          color: colors.current)
        }
        drawButton(c, "PLAY", play, pressed: pressed == .play && pressedInside, colors)
        drawButton(c, "ADD", add, pressed: pressed == .add && pressedInside, colors)
        c.fill(Int(bar.minX), Int(bar.maxY) + 1, Int(bar.width), 1, mix(colors.normalBackground, colors.normal, 0.25))
    }

    private func buttonRects(_ parts: LibraryLayout.Parts) -> (play: CGRect, add: CGRect) {
        let bar = parts.bar
        let addWidth = CGFloat(PixelFont.width(of: "ADD") + 8), playWidth = CGFloat(PixelFont.width(of: "PLAY") + 8)
        let add = CGRect(x: bar.maxX - addWidth, y: bar.minY + 1, width: addWidth, height: 11)
        let play = CGRect(x: add.minX - 3 - playWidth, y: bar.minY + 1, width: playWidth, height: 11)
        return (play, add)
    }

    private func drawButton(_ c: Canvas, _ text: String, _ rect: CGRect, pressed: Bool, _ colors: PlaylistColors) {
        c.fill(rect, mix(colors.normalBackground, colors.normal, pressed ? 0.35 : 0.18))
        let light = mix(colors.normalBackground, colors.normal, 0.5), dark = mix(colors.normalBackground, rgb(0), 0.5)
        c.bevel(Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height), light: pressed ? dark : light, dark: pressed ? light : dark)
        c.text(text, Int(rect.minX) + 4, Int(rect.minY) + 3, colors.current)
    }

    private func draw(_ block: LibraryLayout.Block, at y: Int, _ c: Canvas, _ parts: LibraryLayout.Parts,
                      _ colors: PlaylistColors, _ dim: CGColor) {
        let left = Int(parts.list.minX), width = Int(parts.list.width)
        switch block.kind {
        case .header:
            guard let header = shown?.header else { return }
            let size = LibraryLayout.headerCover
            drawCover(c, cover(header.artwork, size: size), left + 1, y + 3, size, colors, dim)
            let x = left + size + 8, room = width - size - 10
            ListFont.draw(ListFont.truncate(header.title, toWidth: room), in: c, x: x, y: y + 8, color: colors.current)
            if let subtitle = header.subtitle {
                ListFont.draw(ListFont.truncate(subtitle, toWidth: room), in: c, x: x, y: y + 21, color: colors.normal)
            }
            if let detail = header.detail {
                ListFont.draw(ListFont.truncate(detail, toWidth: room), in: c, x: x, y: y + 34, color: dim)
            }
        case .shelfTitle(let title):
            ListFont.draw(ListFont.truncate(title, toWidth: width - 4), in: c, x: left + 1, y: y + 3, color: colors.current)
            c.fill(left + 1, y + 15, width - 2, 1, mix(colors.normalBackground, colors.normal, 0.25))
        case .track(let index):
            guard case .track(let track) = items[index] else { return }
            if selection.contains(index) { c.fill(left, y, width, LibraryLayout.rowHeight, colors.selectedBackground) }
            let time = track.duration.map(TimeFormat.clock) ?? ""
            let timeX = left + width - 2 - ListFont.width(of: time)
            let artistX = left + width * 55 / 100
            ListFont.draw(time, in: c, x: timeX, y: y + 1, color: colors.normal)
            ListFont.draw(ListFont.truncate(track.title, toWidth: artistX - left - 8), in: c, x: left + 2, y: y + 1, color: colors.normal)
            if let artist = track.artist {
                ListFont.draw(ListFont.truncate(artist, toWidth: timeX - artistX - 6), in: c, x: artistX, y: y + 1, color: dim)
            }
        case .grid(let indices):
            for (column, index) in indices.enumerated() {
                guard case .place(let place) = items[index] else { continue }
                let cell = Int(LibraryLayout.cell.width), size = LibraryLayout.cover
                let x = left + column * cell + (cell - size) / 2
                if selection.contains(index) {
                    c.fill(x - 2, y, size + 4, Int(LibraryLayout.cell.height) - 2, colors.selectedBackground)
                }
                drawCover(c, cover(place.artwork, size: size), x, y + 2, size, colors, dim)
                let textWidth = cell - 4
                let textX = left + column * cell + 2
                ListFont.draw(ListFont.truncate(place.title, toWidth: textWidth), in: c, x: textX, y: y + size + 4, color: colors.normal)
                if let subtitle = place.subtitle {
                    ListFont.draw(ListFont.truncate(subtitle, toWidth: textWidth), in: c, x: textX, y: y + size + 4 + ListFont.lineHeight,
                                  color: dim)
                }
            }
        }
    }

    /// A cover, or until it loads, a plate with a note on it.
    private func drawCover(_ c: Canvas, _ image: CGImage?, _ x: Int, _ y: Int, _ size: Int, _ colors: PlaylistColors, _ dim: CGColor) {
        if let image {
            c.draw(image, x, y)
            return
        }
        c.fill(x, y, size, size, mix(colors.normalBackground, colors.normal, 0.1))
        c.bevel(x, y, size, size, light: mix(colors.normalBackground, colors.normal, 0.25), dark: mix(colors.normalBackground, rgb(0), 0.4))
        // ♪
        let (nx, ny) = (x + size / 2 - 2, y + size / 2 - 4)
        c.fill(nx + 3, ny, 1, 7, dim)
        c.fill(nx + 4, ny, 2, 1, dim)
        c.fill(nx, ny + 6, 4, 2, dim)
    }

    // MARK: - Hit testing

    /// The item at `point` in the list, by its index in `items`.
    private func item(at point: CGPoint) -> Int? {
        let parts = self.parts
        guard parts.list.contains(point) else { return nil }
        let y = Int(point.y - parts.list.minY + scroll)
        guard let block = blocks.first(where: { y >= $0.y && y < $0.y + $0.height }) else { return nil }
        switch block.kind {
        case .track(let index): return index
        case .grid(let indices):
            let column = Int(point.x - parts.list.minX) / Int(LibraryLayout.cell.width)
            return indices.indices.contains(column) ? indices[column] : nil
        case .header, .shelfTitle: return nil
        }
    }

    private func sidebarPlace(at point: CGPoint) -> PakPlace? {
        let parts = self.parts
        guard parts.sidebar.contains(point), Int(point.y) >= parts.sectionsTop else { return nil }
        var y = parts.sectionsTop - Int(sidebarScroll)
        for (index, entry) in sidebar.enumerated() {
            if entry.place == nil, index > 0 { y += 3 }
            if Int(point.y) >= y, Int(point.y) < y + LibraryLayout.sidebarRow { return entry.place }
            y += LibraryLayout.sidebarRow
        }
        return nil
    }

    private var backRect: CGRect {
        let bar = parts.bar
        return CGRect(x: bar.minX, y: bar.minY, width: CGFloat(ListFont.width(of: "< Back") + 4), height: bar.height)
    }

    private func press(at point: CGPoint) -> Press? {
        let parts = self.parts
        let frame = PanelFrame(skin: skin, size: pixelSize, title: title, active: isActive)
        if frame.close.contains(point) { return .close }
        if parts.grip.contains(point) { return .grip(startSize: .zero, startMouse: .zero) }
        if isScrollable, parts.scrollTrack.contains(point) { return .thumb(grab: 0) }
        if parts.search.contains(point) { return .search }
        let (play, add) = buttonRects(parts)
        if play.contains(point) { return .play }
        if add.contains(point) { return .add }
        if !history.isEmpty, backRect.contains(point) { return .back }
        if parts.content.contains(point) { return .items }
        return nil
    }

    // MARK: - Mouse

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let press = press(at: point) else { return false }
        switch press {
        case .search:
            _ = search.mouseDown(at: point, event: event)
            pressed = .search
            return true
        case .grip:
            pressed = .grip(startSize: window?.frame.size ?? frame.size, startMouse: NSEvent.mouseLocation)
            return true
        case .thumb:
            let thumb = thumbRect
            if thumb.contains(point) {
                pressed = .thumb(grab: point.y - thumb.minY)
            } else {
                scroll += point.y < thumb.minY ? -parts.list.height : parts.list.height
            }
            return true
        case .items:
            window?.makeFirstResponder(self)
            if let place = sidebarPlace(at: point) {
                openSection(place)
            } else if let index = item(at: point) {
                let plain = event.modifierFlags.isDisjoint(with: [.command, .shift])
                // A plain click on a selected item keeps the rest selected, in case it's dragged.
                if plain && selection.contains(index) {
                    focus = index
                    anchor = index
                } else {
                    select(index, event: event)
                }
                itemPress = (point, index, plain && selection.count > 1)
                pressed = .items
                if event.clickCount == 2 { activate(index) }
            } else if parts.list.contains(point) {
                selection = []
                focus = nil
            }
            return true
        default:
            pressed = press
            pressedInside = true
            return true
        }
    }

    private func select(_ index: Int, event: NSEvent) {
        focus = index
        let modifiers = event.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else if modifiers.contains(.shift), let anchor {
            selection = IndexSet(integersIn: min(anchor, index)...max(anchor, index))
        } else {
            selection = [index]
            anchor = index
        }
    }

    /// Opens an album, artist or playlist, keeping this page for Back.
    func open(_ place: PakPlace) {
        open(.place(place.id), title: place.title, pushing: true)
    }

    /// Double-click: open a place, play a song.
    private func activate(_ index: Int) {
        switch items[index] {
        case .place(let place): open(place)
        case .track(let track): add([track], play: true)
        }
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        switch pressed {
        case .search?:
            search.mouseDragged(to: point)
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
        case .items?:
            guard let press = itemPress, hypot(point.x - press.point.x, point.y - press.point.y) >= 3 else { return }
            itemPress = nil
            beginDrag(event)
        case .thumb(let grab)?:
            let track = parts.scrollTrack
            let travel = track.height - PlaylistLayout.scrollThumb.height
            let t = travel > 0 ? min(max((point.y - grab - track.minY) / travel, 0), 1) : 0
            scroll = t * max(0, CGFloat(contentHeight) - parts.list.height)
        case let press?:
            pressedInside = self.press(at: point) == press
        case nil:
            break
        }
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            pressed = nil
            pressedInside = false
        }
        if let press = itemPress, press.collapse {
            selection = [press.index]
        }
        itemPress = nil
        switch pressed {
        case .search?: search.mouseUp()
        case .close? where pressedInside: windowGroup?.setVisible(.library, false)
        case .back? where pressedInside: goBack()
        case .play? where pressedInside: playOrAdd(play: true)
        case .add? where pressedInside: playOrAdd(play: false)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let pixels = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / scale : event.scrollingDeltaY * CGFloat(LibraryLayout.rowHeight) * 3
        if parts.sidebar.contains(pixel(for: event)) {
            let parts = self.parts
            let room = parts.sidebar.maxY - CGFloat(parts.sectionsTop)
            sidebarScroll = min(max(sidebarScroll - pixels, 0), max(0, sidebarHeight - room))
            needsDisplay = true
        } else {
            scroll -= pixels
        }
    }

    /// The sections' height, headings' gaps included.
    private var sidebarHeight: CGFloat {
        CGFloat(sidebar.count * LibraryLayout.sidebarRow + max(0, sidebar.filter { $0.place == nil }.count - 1) * 3 + 4)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = pixel(for: event)
        guard let index = item(at: point) else { return Menus.context() }
        if !selection.contains(index) { selection = [index] }
        needsDisplay = true
        let menu = NSMenu()
        if case .place(let place) = items[index], selection.count == 1 {
            let open = NSMenuItem(title: "Open “\(place.title)”", action: #selector(openSelected(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }
        for (title, action) in [("Play", #selector(playSelected(_:))), ("Add to Playlist", #selector(addSelected(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openSelected(_ sender: Any?) {
        if let index = selection.first { activate(index) }
    }

    @objc private func playSelected(_ sender: Any?) { playOrAdd(play: true) }
    @objc private func addSelected(_ sender: Any?) { playOrAdd(play: false) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        defer { needsDisplay = true }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            search.focus()
            return
        }
        let extend = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            if selection.count == 1, let index = selection.first, case .place = items[index] {
                activate(index)
            } else {
                playOrAdd(play: true)
            }
        case .delete?, .backspace?:
            goBack()
        case .leftArrow?: moveFocus(to: (focus ?? 1) - 1, extend: extend)
        case .rightArrow?: moveFocus(to: focus.map { $0 + 1 } ?? 0, extend: extend)
        case .upArrow?: moveFocus(to: focus.map { row(from: $0, by: -1) } ?? 0, extend: extend)
        case .downArrow?: moveFocus(to: focus.map { row(from: $0, by: 1) } ?? 0, extend: extend)
        case .pageUp?: moveFocus(to: focus.map { page(from: $0, by: -1) } ?? 0, extend: extend)
        case .pageDown?: moveFocus(to: focus.map { page(from: $0, by: 1) } ?? 0, extend: extend)
        case .home?: moveFocus(to: 0, extend: extend)
        case .end?: moveFocus(to: items.count - 1, extend: extend)
        case .tab?: search.focus()
        default:
            if let keyFallback { keyFallback.keyDown(with: event) } else { super.keyDown(with: event) }
        }
    }

    /// Moves the focus, and the selection with it (or from the anchor, extending), and
    /// scrolls it into view.
    func moveFocus(to index: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        let index = min(max(index, 0), items.count - 1)
        if extend {
            let start = anchor ?? index
            selection = IndexSet(integersIn: min(start, index)...max(start, index))
            anchor = start
        } else {
            selection = [index]
            anchor = index
        }
        focus = index
        let block = blocks[positions[index].block]
        let top = CGFloat(block.y), bottom = CGFloat(block.y + block.height)
        if top < scroll {
            scroll = top
        } else if bottom > scroll + parts.list.height {
            scroll = bottom - parts.list.height
        }
    }

    /// The item a row above or below `index` (`step` -1 or 1): in the same column of a row
    /// of covers, or the nearest one when that row is shorter.
    private func row(from index: Int, by step: Int) -> Int {
        let (block, column) = positions[index]
        var number = block + step
        while blocks.indices.contains(number) {
            switch blocks[number].kind {
            case .track(let target): return target
            case .grid(let indices): return indices[min(column, indices.count - 1)]
            case .header, .shelfTitle: number += step
            }
        }
        return index
    }

    /// The item about a list's height above or below `index`.
    private func page(from index: Int, by step: Int) -> Int {
        let start = blocks[positions[index].block].y
        var target = index
        while true {
            let next = row(from: target, by: step)
            guard next != target else { return target }
            target = next
            if abs(blocks[positions[target].block].y - start) >= Int(parts.list.height) - LibraryLayout.rowHeight { return target }
        }
    }

    // MARK: - Dragging into the playlist

    private func beginDrag(_ event: NSEvent) {
        guard canAsk, !selection.isEmpty else { return }
        dragged = selection.map { items[$0] }
        let item = NSPasteboardItem()
        item.setString(String(dragged.count), forType: Self.draggedItems)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage()
        let location = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(x: location.x - image.size.width / 2, y: location.y - image.size.height / 2,
                                             width: image.size.width, height: image.size.height), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// The first dragged item's cover with how many there are, or just the count.
    private func dragImage() -> NSImage {
        let colors = skin.playlistColors
        let label = dragged.count == 1 ? (dragged[0].track?.title ?? dragged[0].place?.title ?? "") : "\(dragged.count) items"
        let text = ListFont.truncate(label, toWidth: 120)
        let artwork = dragged.first.flatMap { $0.place?.artwork ?? $0.track?.artwork }
        let cover = pak.flatMap { pak in artwork.flatMap { covers.cached(CoverCache.Key(pak: pak.id, artwork: $0, size: LibraryLayout.cover)) } }
        let size = LibraryLayout.cover
        let canvas = Canvas(max(size, ListFont.width(of: text) + 6), size + ListFont.lineHeight + 4)
        if let cover { canvas.draw(cover, (canvas.width - size) / 2, 0) }
        canvas.fill(0, size + 1, canvas.width, ListFont.lineHeight + 2, colors.selectedBackground)
        ListFont.draw(text, in: canvas, x: 3, y: size + 2, color: colors.current)
        return NSImage(cgImage: canvas.image(), size: NSSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    /// Puts what was dragged out into the playlist at `index`: songs as they are, albums and
    /// playlists as all their songs.
    func dropDragged(at index: Int) {
        let items = dragged
        dragged = []
        insert(items, at: index)
    }

    func insert(_ items: [PakItem], at index: Int) {
        guard let pak, canAsk, !items.isEmpty else { return }
        Task {
            var tracks: [PakTrack] = []
            for item in items {
                switch item {
                case .track(let track): tracks.append(track)
                case .place(let place): tracks += (try? await pak.allTracks(at: .place(place.id))) ?? []
                }
            }
            guard !tracks.isEmpty else { return }
            remember(tracks)
            controller.insert(tracks.map(\.url), at: min(index, controller.queue.count))
        }
    }

    // MARK: - Playing and adding

    /// What's selected, or with nothing selected, the whole album or playlist shown.
    func playOrAdd(play: Bool) {
        guard let pak, canAsk, let shown else { return }
        let picked = selection.map { items[$0] }
        guard !picked.isEmpty || shown.header != nil else {
            flashMessage?("SELECT SOMETHING TO \(play ? "PLAY" : "ADD")")
            return
        }
        let location = shown.location
        Task {
            var tracks: [PakTrack] = []
            if picked.isEmpty {
                tracks = (try? await pak.allTracks(at: location)) ?? []
            }
            for item in picked {
                switch item {
                case .track(let track): tracks.append(track)
                case .place(let place): tracks += (try? await pak.allTracks(at: .place(place.id))) ?? []
                }
            }
            add(tracks, play: play)
        }
    }

    /// Seeds the playlist's titles, so new rows show names before the Pak is asked.
    private func remember(_ tracks: [PakTrack]) {
        for track in tracks {
            controller.info.seed(TrackMetadata(title: track.title, artist: track.artist, duration: track.duration), for: track.url)
        }
    }

    private func add(_ tracks: [PakTrack], play: Bool) {
        guard !tracks.isEmpty else {
            flashMessage?("NOTHING TO \(play ? "PLAY" : "ADD")")
            return
        }
        remember(tracks)
        let first = controller.queue.count
        controller.enqueue(tracks.map(\.url))
        if play {
            controller.playItem(at: first)
        } else {
            flashMessage?(tracks.count == 1 ? "ADDED 1 SONG" : "ADDED \(tracks.count) SONGS")
        }
    }
}
