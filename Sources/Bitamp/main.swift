import AppKit
import BitampKit

OldSettings.copyIfNeeded()

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
