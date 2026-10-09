import AppKit
import BitampAppleMusicPak
import BitampKit

// `Bitamp --check-pak <folder.bitpak>` tries a Pak for its author, then exits. See docs/PAK-SDK.md.
if CommandLine.arguments.dropFirst().first == "--check-pak" {
    let reserved = MainActor.assumeIsolated { AppleMusicPak().id }
    PakCheck.main(Array(CommandLine.arguments.dropFirst(2)), reservedIDs: [reserved])
}

OldSettings.copyIfNeeded()

MainActor.assumeIsolated {
    let delegate = AppDelegate(paks: [AppleMusicPak()])
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
