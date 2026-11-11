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
        costs: ["Sonnet 5.5": "About 4 cents a song", "Opus 5.5": "Richer notes, about 10 to 15 cents a song"],
        summary: "Richest notes, with sources. About 4 cents."
    ) { model, key in
        ClaudeBackstory(key: key, model: model == "Opus 5.5" ? .opus : .sonnet)
    }
    let openAI = BackstoryPak.Provider(
        name: "OpenAI", models: ["GPT-5 mini", "GPT-5.5"],
        costs: ["GPT-5 mini": "About 2 cents a song", "GPT-5.5": "Richer notes, about 7 cents a song"],
        summary: "Notes with sources. About 2 cents."
    ) { model, key in
        OpenAIBackstory(key: key, model: model == "GPT-5.5" ? .full : .mini)
    }
    // Apple's on-device model, offered where macOS has it, and marked wherever it's used.
    let onDevice = AppleOnDevice.isSupported
        ? BackstoryPak.OnDevice(isAvailable: { AppleOnDevice.isAvailable }, make: { wikipedia in
            AppleOnDevice.service(wikipedia: wikipedia ? WikipediaFacts() : nil)
        }) : nil
    let delegate = AppDelegate(paks: [AppleMusicPak()], backstory: [claude, openAI], backstoryOnDevice: onDevice)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
