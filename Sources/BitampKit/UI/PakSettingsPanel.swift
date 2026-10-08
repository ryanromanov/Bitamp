import AppKit
import BitampPakProtocol

/// A third-party Pak's settings, as a form built from what its manifest lists: text
/// fields, password fields (kept in the Keychain) and pop-up menus.
@MainActor
final class PakSettingsPanel: NSPanel {
    private let pak: ExternalPak
    private var fields: [(PakSettingDefinition, NSControl)] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(pak: ExternalPak) {
        self.pak = pak
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "\(pak.name) Pak Settings"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let values = pak.settingValues()
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for setting in pak.manifest.settings ?? [] {
            let control = Self.control(for: setting, value: values[setting.key])
            fields.append((setting, control))
            let label = NSTextField(labelWithString: setting.label + ":")
            label.alignment = .right
            grid.addRow(with: [label, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        if grid.numberOfColumns > 1 { grid.column(at: 1).width = 220 }

        if let description = pak.manifest.description {
            status.stringValue = description
        }
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 340

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton])

        let stack = NSStackView(views: [grid, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 340).isActive = true
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    private static func control(for setting: PakSettingDefinition, value: String?) -> NSControl {
        switch setting.kind {
        case .text:
            return NSTextField(string: value ?? "")
        case .password:
            return NSSecureTextField(string: value ?? "")
        case .choice:
            let popUp = NSPopUpButton()
            popUp.addItems(withTitles: setting.options ?? [])
            if let value { popUp.selectItem(withTitle: value) }
            return popUp
        }
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func save(_ sender: Any?) {
        var values: [String: String] = [:]
        for (setting, control) in fields {
            values[setting.key] = (control as? NSPopUpButton)?.titleOfSelectedItem ?? control.stringValue
        }
        saveButton.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Checking…"
        Task {
            defer { saveButton.isEnabled = true }
            do {
                try await pak.configure(values)
                if case .limited(let reason) = pak.account {
                    status.stringValue = reason
                } else if case .disconnected = pak.account {
                    status.textColor = .systemRed
                    status.stringValue = "Saved, but the Pak still can't connect. Check the settings."
                } else {
                    close()
                }
            } catch {
                status.textColor = .systemRed
                status.stringValue = error.localizedDescription
            }
        }
    }
}
