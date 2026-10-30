import AppKit
import BitampAppleMusicPak
import BitampKit
import BitampBackstory

// `Bitamp --check-pak <folder.bitpak>` tries a Pak for its author, then exits. See docs/PAK-SDK.md.
if CommandLine.arguments.dropFirst().first == "--check-pak" {
    let reserved = MainActor.assumeIsolated { AppleMusicPak().id }
    PakCheck.main(Array(CommandLine.arguments.dropFirst(2)), reservedIDs: [reserved])
}

OldSettings.copyIfNeeded()

MainActor.assumeIsolated {
    let claude = BackstoryPak.Provider(
        name: "Claude", models: ["Sonnet 5.5", "Opus 5.5"],
        costs: ["Sonnet 5.5": "About 4 cents a song", "Opus 5.5": "Richer notes, about 10 to 15 cents a song"]
    ) { model, key in
        ClaudeBackstory(key: key, model: model == "Opus 5.5" ? .opus : .sonnet)
    }
    // Apple's on-device model, offered where macOS has it, and marked wherever it's used.
    let onDevice = AppleOnDevice.isSupported
        ? BackstoryPak.OnDevice(isAvailable: { AppleOnDevice.isAvailable }, make: { AppleOnDevice.service() }) : nil
    let delegate = AppDelegate(paks: [AppleMusicPak()], backstory: [claude], backstoryOnDevice: onDevice)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
