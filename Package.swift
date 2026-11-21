// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bitamp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Bitamp", targets: ["Bitamp"]),
        // For spikes/musickit, which tries the Pak from a signed app of its own.
        .library(name: "BitampAppleMusicPak", targets: ["BitampAppleMusicPak"]),
        // For third-party Paks written in Swift. See docs/PAK-SDK.md.
        .library(name: "BitampPakSDK", targets: ["BitampPakSDK"]),
        .executable(name: "BitampDemoPak", targets: ["BitampDemoPak"]),
        .executable(name: "BitampDemoNotesPak", targets: ["BitampDemoNotesPak"]),
        .executable(name: "BitampDemoPlaybackPak", targets: ["BitampDemoPlaybackPak"]),
        // Apple Music as a Pak of its own. Needs a signed app bundle: scripts/make-applemusic-pak.sh.
        .executable(name: "BitampAppleMusicHelper", targets: ["BitampAppleMusicHelper"]),
    ],
    targets: [
        // Everything but the entry point lives in BitampKit so tests can import it.
        .target(
            name: "BitampKit", dependencies: ["BitampAtomics", "BitampPakKit", "BitampPakProtocol"],
            // Core ML models, compiled when first used: Basic Pitch (see BasicPitch.swift)
            // and MSNet vocal (scripts/msnet/convert.py).
            resources: [.copy("Resources/BasicPitch"), .copy("Resources/MSNet"), .copy("Resources/Presets")]),
        .target(name: "BitampAtomics"),
        // What an Expansion Pak sees of Bitamp: protocols and value types only. See docs/PAKS.md.
        .target(name: "BitampPakKit"),
        // Third-party Paks: the messages Bitamp and a Pak's program exchange, the Swift
        // library for writing one, and the demo Paks (packaged by scripts/make-pak.sh): one
        // with music, and a companion that writes notes.
        .target(name: "BitampPakProtocol"),
        .target(name: "BitampPakSDK", dependencies: ["BitampPakProtocol"]),
        .executableTarget(name: "BitampDemoPak", dependencies: ["BitampPakSDK"], exclude: ["pak.json"]),
        .executableTarget(name: "BitampDemoNotesPak", dependencies: ["BitampPakSDK"], exclude: ["pak.json"]),
        // Shares the Demo Pak's tunes and synthesizer (symlinked), and plays them itself.
        .executableTarget(name: "BitampDemoPlaybackPak", dependencies: ["BitampPakSDK"], exclude: ["pak.json"]),
        // Expansion Paks built into Bitamp. Each depends on BitampPakKit only.
        .target(name: "BitampAppleMusicPak", dependencies: ["BitampPakKit"]),
        // The Apple Music Pak again, as a program Bitamp runs: it answers the Pak protocol with
        // BitampAppleMusicPak. Not packaged by make-pak.sh (hence helper-pak.json), because
        // MusicKit needs the program to be a signed app with a provisioning profile.
        .executableTarget(
            name: "BitampAppleMusicHelper", dependencies: ["BitampAppleMusicPak", "BitampPakKit", "BitampPakSDK"],
            exclude: ["helper-pak.json"]),
        // The services the Backstory Pak can ask about a song (Claude so far).
        .target(name: "BitampBackstory", dependencies: ["BitampPakKit"]),
        .executableTarget(name: "Bitamp", dependencies: ["BitampKit", "BitampAppleMusicPak", "BitampBackstory"]),
        .testTarget(name: "BitampTests", dependencies: [
            "BitampKit", "BitampPakKit", "BitampAppleMusicPak", "BitampPakSDK", "BitampDemoPak", "BitampDemoNotesPak", "BitampDemoPlaybackPak", "BitampBackstory",
            "BitampAppleMusicHelper",
        ]),
    ]
)
