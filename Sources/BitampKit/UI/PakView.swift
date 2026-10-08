import AppKit

/// Where things sit in the Expansion Paks window, in skin pixels.
enum PakLayout {
    /// The window with one row of slots; each row past the first adds `rowHeight`.
    static let size = CGSize(width: 275, height: 116)
    static let rowHeight = 84
    static let top = 20
    static let bottom = 12
    static let left = 12
    /// The playlist's right tile is 20 wide, but the content covers its scrollbar groove.
    static let rightTile = 20
    static let right = 7
    static let slotCount = 3
    static let slotWidth = 76
    static let slotGap = 7
    /// The cartridge's top edge when inserted, and how far it rises when ejected: all the
    /// way out of the slot, with a gap under its contacts.
    static let cartridgeTop = 42
    static let ejectRise = 20
    /// Tall enough that an inserted cartridge's bottom stays hidden behind the plate.
    static let cartridgeSize = CGSize(width: 59, height: 48)
    /// The socket's front plate, which hides the inserted part of the cartridge.
    static let plateY = 84
    static let plateHeight = 8
    static let statusY = 95

    static func rows(for count: Int) -> Int {
        max(1, (count + slotCount - 1) / slotCount)
    }

    /// Room for `count` Paks, three to a row.
    static func size(for count: Int) -> CGSize {
        CGSize(width: size.width, height: size.height + CGFloat((rows(for: count) - 1) * rowHeight))
    }

    static func content(in size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: Int(size.width) - left - right, height: Int(size.height) - top - bottom)
    }

    static func slot(_ index: Int) -> CGRect {
        let column = index % slotCount, row = index / slotCount
        return CGRect(x: left + slotGap + column * (slotWidth + slotGap), y: top + row * rowHeight,
                      width: slotWidth, height: rowHeight)
    }

    /// `y` measured from the top of the first row, moved to `index`'s row.
    private static func inRow(_ index: Int, _ y: Int) -> CGFloat {
        slot(index).minY + CGFloat(y - top)
    }

    static func cartridge(_ index: Int, rise: Int) -> CGRect {
        let slot = slot(index)
        return CGRect(
            x: slot.minX + ((slot.width - cartridgeSize.width) / 2).rounded(.down),
            y: inRow(index, cartridgeTop - rise), width: cartridgeSize.width, height: cartridgeSize.height)
    }

    /// The front plate, which inserts or ejects the cartridge when clicked.
    static func plate(_ index: Int) -> CGRect {
        let slot = slot(index)
        return CGRect(x: slot.minX + 2, y: inRow(index, plateY), width: slot.width - 4, height: CGFloat(plateHeight))
    }

    static func statusY(_ index: Int) -> Int {
        Int(inRow(index, statusY))
    }

    static func close(in size: CGSize) -> CGRect {
        PlaylistLayout.close(in: size)
    }
}

/// The Expansion Paks window: each Pak as an N64-style cartridge in a slot. Click a
/// cartridge to search it, click the slot's front plate to eject or insert it.
///
/// The frame borrows the playlist's title and side tiles, so `.wsz` skins dress it too;
/// the cartridges are drawn in fixed colors, as the plastic things they are. Dropping a
/// `.bitpak` on the window installs it.
final class PakView: SkinnedView {
    let controller: PlaybackController
    /// Opens the "Add from…" search for a Pak.
    var onSearch: ((Pak) -> Void)?
    /// Opens a third-party Pak's settings.
    var onSettings: ((ExternalPak) -> Void)?
    /// Installs a dropped `.bitpak`.
    var onInstall: ((URL) -> Void)?
    /// Asks whether to remove a third-party Pak, and does.
    var onRemove: ((ExternalPak) -> Void)?
    /// Called after a Pak is inserted (true) or ejected (false).
    var onInsertedChange: ((Pak, Bool) -> Void)?

    private var paks: [Pak] { controller.paks.paks }
    /// How far each cartridge has risen out of its slot, animated toward 0 or `ejectRise`.
    private var rise: [String: Double] = [:]
    /// Account states, read a few times a second rather than every frame.
    private var accounts: [String: PakAccount] = [:]
    private var pressed: Press?
    private var pressedInside = false

    private enum Press: Equatable {
        case close
        case cartridge(Int)
        case plate(Int)
    }

    // The cartridge's plastic and label.
    private static let plastic = rgb(0x8C8C8C)
    private static let plasticLight = rgb(0xB4B4B4)
    private static let plasticDark = rgb(0x555555)
    private static let outline = rgb(0x262626)
    private static let label = rgb(0xE6E2D6)
    private static let labelText = rgb(0x1E1E1E)
    private static let ledOn = rgb(0x3CE63C)
    private static let ledWaiting = rgb(0xF0A800)
    private static let ledOff = rgb(0x3A2A2A)
    private static let contacts = rgb(0xD4A531)

    init(controller: PlaybackController, skin: Skin, scale: CGFloat) {
        self.controller = controller
        super.init(pixelSize: PakLayout.size(for: controller.paks.paks.count), skin: skin, scale: scale)
        refreshAccounts()
        for pak in paks { rise[pak.id] = targetRise(pak) }
        registerForDraggedTypes([.fileURL])
    }

    /// Call after Paks are installed or removed: the window grows or shrinks to fit them.
    func paksChanged() {
        refreshAccounts()
        for pak in paks where rise[pak.id] == nil { rise[pak.id] = targetRise(pak) }
        resizeKeepingTopLeft()
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func normalizedPixelSize(_ proposed: CGSize) -> CGSize {
        PakLayout.size(for: paks.count)
    }

    private var slotCount: Int {
        PakLayout.rows(for: paks.count) * PakLayout.slotCount
    }

    private func targetRise(_ pak: Pak) -> Double {
        pak.isAvailable && controller.paks.isInserted(pak) ? 0 : Double(PakLayout.ejectRise)
    }

    private func refreshAccounts() {
        for pak in paks where pak.isAvailable { accounts[pak.id] = pak.account }
    }

    override func tick() {
        if frameCount % 10 == 0 { refreshAccounts() }
        // Slide toward inserted or ejected, a pixel or so a frame.
        for pak in paks {
            let target = targetRise(pak)
            let current = rise[pak.id] ?? target
            rise[pak.id] = abs(target - current) < 0.6 ? target : current + (target - current) * 0.35
        }
    }

    // MARK: - Drawing

    override func render(into c: Canvas) {
        let size = pixelSize
        let (w, h) = (Int(size.width), Int(size.height))
        let colors = skin.playlistColors

        // Frame: the playlist's top and side tiles, a closing strip from its bottom tile.
        for x in stride(from: 0, to: w, by: 25) {
            c.draw(skin.image(for: .playlistBottomTile), x, h - PakLayout.bottom)
        }
        for x in stride(from: 25, to: w - 25, by: 25) {
            c.draw(skin.image(for: .playlistTopTile(active: isActive)), x, 0)
        }
        c.draw(skin.image(for: .playlistTopLeft(active: isActive)), 0, 0)
        c.draw(skin.image(for: .playlistTopRight(active: isActive)), w - 25, 0)
        for y in stride(from: PakLayout.top, to: h - PakLayout.bottom, by: Int(PlaylistLayout.heightStep)) {
            c.draw(skin.image(for: .playlistLeftTile), 0, y)
            c.draw(skin.image(for: .playlistRightTile), w - PakLayout.rightTile, y)
        }
        c.draw(skin.image(for: .playlistCloseButton(pressed: pressed == .close && pressedInside)),
               at: PakLayout.close(in: size).origin)
        drawTitle(c, colors)

        c.fill(PakLayout.content(in: size), colors.normalBackground)
        for index in 0..<slotCount {
            if index < paks.count {
                drawSlot(c, index, pak: paks[index], colors)
            } else {
                drawEmptySlot(c, index, colors)
            }
        }
    }

    /// "EXPANSION PAKS" on a plate in the middle of the title bar, where the playlist's
    /// title sprite would go.
    private func drawTitle(_ c: Canvas, _ colors: PlaylistColors) {
        let title = "EXPANSION PAKS"
        let width = PixelFont.width(of: title) + 5
        let x = (Int(pixelSize.width) - width) / 2
        c.fill(x, 5, width, 10, colors.normalBackground)
        c.text(title, x + 3, 7, isActive ? colors.current : colors.normal)
    }

    private func drawSlot(_ c: Canvas, _ index: Int, pak: Pak, _ colors: PlaylistColors) {
        let slot = PakLayout.slot(index)
        let inserted = pak.isAvailable && controller.paks.isInserted(pak)
        let rise = Int((rise[pak.id] ?? 0).rounded())
        drawSocket(c, slot, colors)
        drawCartridge(c, PakLayout.cartridge(index, rise: rise), pak: pak, inserted: inserted,
                      pressed: pressed == .cartridge(index) && pressedInside)
        drawPlate(c, index, colors, inserted: inserted, pressed: pressed == .plate(index) && pressedInside)
        drawStatus(c, index, status(of: pak, inserted: inserted), colors.normal)
    }

    private func drawEmptySlot(_ c: Canvas, _ index: Int, _ colors: PlaylistColors) {
        let slot = PakLayout.slot(index)
        drawSocket(c, slot, colors)
        drawPlate(c, index, colors, inserted: nil, pressed: false)
        drawStatus(c, index, "EMPTY", mix(colors.normal, colors.normalBackground, 0.5))
    }

    /// The dark opening the cartridge sits in.
    private func drawSocket(_ c: Canvas, _ slot: CGRect, _ colors: PlaylistColors) {
        let x = Int(slot.minX) + 4, width = Int(slot.width) - 8
        let shadow = mix(colors.normalBackground, rgb(0x000000), 0.6)
        c.fill(x, Int(slot.minY) + PakLayout.plateY - PakLayout.top - 4, width, 4, shadow)
    }

    private func drawCartridge(_ c: Canvas, _ rect: CGRect, pak: Pak, inserted: Bool, pressed: Bool) {
        let (x, y, w, h) = (Int(rect.minX), Int(rect.minY) + (pressed ? 1 : 0), Int(rect.width), Int(rect.height))
        let dim = !inserted
        func shade(_ color: CGColor) -> CGColor { dim ? mix(color, Self.plasticDark, 0.3) : color }

        // The narrower edge at the bottom with its gold contacts, seen only once it's out.
        let tab = 6, inset = 5
        c.fill(x + inset, y + h - tab - 1, w - inset * 2, tab + 1, Self.outline)
        c.fill(x + inset + 1, y + h - tab - 1, w - inset * 2 - 2, tab, shade(Self.plasticDark))
        for pin in stride(from: x + inset + 3, to: x + w - inset - 3, by: 3) {
            c.fill(pin, y + h - 5, 2, 4, shade(Self.contacts))
        }
        // Body.
        let bodyHeight = h - tab
        c.fill(x, y, w, bodyHeight, Self.outline)
        c.fill(x + 1, y + 1, w - 2, bodyHeight - 2, shade(Self.plastic))
        c.fill(x + 1, y + 1, w - 2, 1, shade(Self.plasticLight))
        c.fill(x + 1, y + 1, 1, bodyHeight - 2, shade(Self.plasticLight))
        c.fill(x + w - 2, y + 2, 1, bodyHeight - 3, shade(Self.plasticDark))
        // Grip ridges.
        for ridge in 0..<3 {
            c.fill(x + 8, y + 3 + ridge * 2, w - 16, 1, shade(Self.plasticDark))
        }
        // Label, with the Pak's name over two lines.
        let label = CGRect(x: x + 5, y: y + 11, width: w - 10, height: 23)
        c.fill(label, shade(Self.label))
        let lines = Self.labelLines(pak.name.uppercased(), width: Int(label.width) - 2)
        let textTop = Int(label.minY) + (lines.count == 1 ? 9 : 5)
        for (line, text) in lines.enumerated() {
            let textX = Int(label.minX) + (Int(label.width) - PixelFont.width(of: text) + 1) / 2
            c.text(text, textX, textTop + line * 8, shade(Self.labelText))
        }
        // The light: green when ready, amber when it needs signing in, dark when ejected.
        let led: CGColor
        switch (inserted, accounts[pak.id]) {
        case (false, _): led = Self.ledOff
        case (true, .connected?): led = Self.ledOn
        default: led = Self.ledWaiting
        }
        c.fill(x + w - 9, y + 37, 4, 3, Self.outline)
        c.fill(x + w - 8, y + 37, 2, 2, led)
    }

    /// The front of the slot. A small eject or insert arrow shows what clicking it does.
    private func drawPlate(_ c: Canvas, _ index: Int, _ colors: PlaylistColors, inserted: Bool?, pressed: Bool) {
        let plate = PakLayout.plate(index)
        let (x, y, w, h) = (Int(plate.minX), Int(plate.minY), Int(plate.width), Int(plate.height))
        let face = mix(colors.normalBackground, colors.normal, 0.25)
        let light = mix(colors.normalBackground, colors.normal, 0.5)
        let dark = mix(colors.normalBackground, rgb(0x000000), 0.5)
        c.fill(x, y, w, h, face)
        c.bevel(x, y, w, h, light: pressed ? dark : light, dark: pressed ? light : dark)
        guard let inserted else { return }
        // A 5×3 triangle: pointing up to eject, down to insert.
        let midX = x + w / 2, top = y + 2
        let arrow = pressed ? colors.current : colors.normal
        for row in 0..<3 {
            let half = inserted ? row : 2 - row
            c.fill(midX - half, top + row, half * 2 + 1, 1, arrow)
        }
    }

    private func drawStatus(_ c: Canvas, _ index: Int, _ text: String, _ color: CGColor) {
        let slot = PakLayout.slot(index)
        let maxCharacters = Int(slot.width) / PixelFont.cellWidth
        let text = String(text.prefix(maxCharacters))
        let x = Int(slot.minX) + (Int(slot.width) - PixelFont.width(of: text) + 1) / 2
        c.text(text, x, PakLayout.statusY(index), color)
    }

    private func status(of pak: Pak, inserted: Bool) -> String {
        guard pak.isAvailable else { return "UNAVAILABLE" }
        guard inserted else { return "EJECTED" }
        if controller.playingPak === pak { return "PLAYING" }
        switch accounts[pak.id] {
        case .connected?: return "READY"
        case .limited?: return "LIMITED"
        default: return (pak as? ExternalPak)?.hasSettings == true ? "SET UP" : "SIGN IN"
        }
    }

    /// Splits a name into at most two lines that fit `width` pixels, by words.
    static func labelLines(_ name: String, width: Int) -> [String] {
        let fit = width / PixelFont.cellWidth
        let words = name.split(separator: " ").map(String.init)
        var lines: [String] = []
        for word in words {
            if let last = lines.last, last.count + 1 + word.count <= fit {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines.prefix(2).map { String($0.prefix(fit)) }
    }

    // MARK: - Mouse

    private func press(at point: CGPoint) -> Press? {
        if PakLayout.close(in: pixelSize).contains(point) { return .close }
        for index in paks.indices {
            let plate = PakLayout.plate(index)
            if plate.contains(point) { return .plate(index) }
            let rise = Int((rise[paks[index].id] ?? 0).rounded())
            let cartridge = PakLayout.cartridge(index, rise: rise)
            let visible = CGRect(x: cartridge.minX, y: cartridge.minY, width: cartridge.width,
                                 height: plate.minY - cartridge.minY)
            if visible.contains(point) { return .cartridge(index) }
        }
        return nil
    }

    override func pixelMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let press = press(at: point) else { return false }
        pressed = press
        pressedInside = true
        return true
    }

    override func pixelMouseDragged(to point: CGPoint, event: NSEvent) {
        pressedInside = pressed != nil && press(at: point) == pressed
    }

    override func pixelMouseUp(at point: CGPoint, event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, press(at: point) == pressed else { return }
        switch pressed {
        case .close:
            windowGroup?.setVisible(.paks, false)
        case .cartridge(let index):
            let pak = paks[index]
            if !pak.isAvailable {
                flashMessage?("\(pak.name) PAK NEEDS A NEWER MACOS")
            } else if let external = pak as? ExternalPak, external.hasSettings, external.account == .disconnected {
                onSettings?(external)
            } else if controller.paks.isInserted(pak) {
                onSearch?(pak)
            } else {
                setInserted(true, pak)
            }
        case .plate(let index):
            let pak = paks[index]
            guard pak.isAvailable else { return }
            setInserted(!controller.paks.isInserted(pak), pak)
        }
    }

    private func setInserted(_ inserted: Bool, _ pak: Pak) {
        controller.setInserted(inserted, pak)
        onInsertedChange?(pak, inserted)
        flashMessage?("\(pak.name) PAK \(inserted ? "INSERTED" : "EJECTED")")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard case .cartridge(let index)? = press(at: pixel(for: event)) ?? plateIndex(at: pixel(for: event)) else {
            return Menus.context()
        }
        let pak = paks[index]
        let menu = NSMenu(title: pak.name)
        let inserted = controller.paks.isInserted(pak)
        let search = NSMenuItem(title: "Add from \(pak.name)…", action: inserted && pak.isAvailable ? #selector(searchItem(_:)) : nil, keyEquivalent: "")
        let toggle = NSMenuItem(title: inserted ? "Eject \(pak.name) Pak" : "Insert \(pak.name) Pak",
                                action: pak.isAvailable ? #selector(toggleItem(_:)) : nil, keyEquivalent: "")
        var items = [search, toggle]
        if let external = pak as? ExternalPak {
            items.append(.separator())
            if external.hasSettings {
                items.append(NSMenuItem(title: "\(pak.name) Pak Settings…", action: #selector(settingsItem(_:)), keyEquivalent: ""))
            }
            items.append(NSMenuItem(title: "Remove \(pak.name) Pak…", action: #selector(removeItem(_:)), keyEquivalent: ""))
        }
        for item in items where !item.isSeparatorItem {
            item.target = self
            item.tag = index
        }
        items.forEach(menu.addItem)
        if case .limited(let reason)? = accounts[pak.id] {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: reason, action: nil, keyEquivalent: ""))
        }
        return menu
    }

    /// Right-clicking a slot's plate means its cartridge too.
    private func plateIndex(at point: CGPoint) -> Press? {
        paks.indices.first { PakLayout.plate($0).contains(point) }.map { .cartridge($0) }
    }

    @objc private func settingsItem(_ sender: NSMenuItem) {
        if let pak = paks[sender.tag] as? ExternalPak { onSettings?(pak) }
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        if let pak = paks[sender.tag] as? ExternalPak { onRemove?(pak) }
    }

    // MARK: - Dropping a Pak

    private func droppedPak(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: PakLibrary.isPak)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPak(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedPak(sender) else { return false }
        // After the drop finishes, so the install's confirmation isn't stuck behind it.
        DispatchQueue.main.async { [weak self] in self?.onInstall?(url) }
        return true
    }

    @objc private func searchItem(_ sender: NSMenuItem) {
        onSearch?(paks[sender.tag])
    }

    @objc private func toggleItem(_ sender: NSMenuItem) {
        let pak = paks[sender.tag]
        setInserted(!controller.paks.isInserted(pak), pak)
    }
}
