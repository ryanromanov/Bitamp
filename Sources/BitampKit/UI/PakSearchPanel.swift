import AppKit

/// "Add from Demo…": searches one Pak and adds what's picked to the playlist.
/// A plain AppKit panel for now; a skinned Media Library window can replace it later.
@MainActor
final class PakSearchPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let pak: Pak
    private let controller: PlaybackController
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add to Playlist", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private var results: [PakTrack] = []
    private var search: Task<Void, Never>?

    private enum Column: String, CaseIterable {
        case title = "Title", artist = "Artist", album = "Album", time = "Time"

        var width: CGFloat {
            switch self {
            case .title: return 220
            case .artist, .album: return 150
            case .time: return 50
            }
        }
    }

    init(pak: Pak, controller: PlaybackController) {
        self.pak = pak
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        title = "Add from \(pak.name)"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 420, height: 240)

        field.placeholderString = "Search \(pak.name), then press Return"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(runSearch(_:))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(play(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addButton.target = self
        addButton.action = #selector(add(_:))
        playButton.target = self
        playButton.action = #selector(play(_:))
        playButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [status, addButton, playButton])

        let stack = NSStackView(views: [field, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [field, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        contentView = stack
        updateButtons()
        showAccount()
    }

    func show() {
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        showAccount()
    }

    private func showAccount() {
        switch pak.account {
        case .disconnected: status.stringValue = "Bitamp will ask to use \(pak.name) when you search."
        case .connected: status.stringValue = ""
        case .limited(let reason): status.stringValue = reason
        }
    }

    /// False, with a note in the status line, once the Pak has been ejected.
    private func pakIsInserted() -> Bool {
        guard controller.paks.isInserted(pak) else {
            status.stringValue = "The \(pak.name) Pak is ejected. Insert it in the Expansion Paks window."
            return false
        }
        return true
    }

    @objc private func runSearch(_ sender: Any?) {
        guard pakIsInserted() else { return }
        // An empty search goes through too: some Paks list everything for it.
        let term = field.stringValue
        search?.cancel()
        status.stringValue = "Searching…"
        search = Task {
            do {
                let found = try await pak.search(term)
                guard !Task.isCancelled else { return }
                results = found
                status.stringValue = found.isEmpty ? "Nothing found." : "\(found.count) songs"
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                status.stringValue = error.localizedDescription
            }
            table.reloadData()
            updateButtons()
        }
    }

    private var picked: [PakTrack] {
        table.selectedRowIndexes.map { results[$0] }
    }

    /// Seeds the playlist's titles, so the new rows show names before the Pak is asked.
    private func remember(_ tracks: [PakTrack]) {
        for track in tracks {
            controller.info.seed(TrackMetadata(title: track.title, artist: track.artist, duration: track.duration), for: track.url)
        }
    }

    @objc private func add(_ sender: Any?) {
        let tracks = picked
        guard !tracks.isEmpty, pakIsInserted() else { return }
        remember(tracks)
        controller.enqueue(tracks.map(\.url))
    }

    /// Adds the picked songs to the end of the playlist and plays the first of them.
    @objc private func play(_ sender: Any?) {
        let tracks = picked
        guard !tracks.isEmpty, pakIsInserted() else { return }
        remember(tracks)
        let first = controller.queue.count
        controller.enqueue(tracks.map(\.url))
        controller.playItem(at: first)
    }

    private func updateButtons() {
        let any = table.numberOfSelectedRows > 0
        addButton.isEnabled = any
        playButton.isEnabled = any
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let track = results[row]
        let text: String
        switch column {
        case .title: text = track.title
        case .artist: text = track.artist ?? ""
        case .album: text = track.album ?? ""
        case .time: text = track.duration.map(TimeFormat.clock) ?? ""
        }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = text
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
