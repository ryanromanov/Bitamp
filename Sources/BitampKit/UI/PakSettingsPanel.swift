import AppKit
import BitampPakProtocol

/// A Pak's settings, as a form built from what it lists: text fields, password fields
/// (kept in the Keychain) and pop-up menus.
@MainActor
final class PakSettingsPanel: NSPanel {
    private let pak: ConfigurablePak
    private var fields: [(PakSettingDefinition, NSControl)] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(pak: ConfigurablePak) {
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
        for setting in pak.settingDefinitions {
            let control = Self.control(for: setting, value: values[setting.key])
            fields.append((setting, control))
            // A text field is as wide as its text, so a long key would push past the window.
            if control is NSTextField {
                control.translatesAutoresizingMaskIntoConstraints = false
                control.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
            }
            let label = NSTextField(labelWithString: setting.label + ":")
            label.alignment = .right
            grid.addRow(with: [label, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        if grid.numberOfColumns > 1 { grid.column(at: 1).width = Self.fieldWidth }
        if let description = pak.settingsDescription {
            status.stringValue = description
        }
        status.textColor = .secondaryLabelColor
        // The rows set the form's width; the description and status wrap to it.
        status.preferredMaxLayoutWidth = max(grid.fittingSize.width, 340)

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton])

        let content = NSView()
        for view in [grid, status, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -margin),
            status.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            status.widthAnchor.constraint(equalToConstant: status.preferredMaxLayoutWidth),
            buttons.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        contentView = content
        setContentSize(content.fittingSize)
    }

    static let fieldWidth: CGFloat = 260

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
