import AppKit
import BitampAppleMusicPak
import BitampKit

OldSettings.copyIfNeeded()

MainActor.assumeIsolated {
    let delegate = AppDelegate(paks: [AppleMusicPak()])
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
