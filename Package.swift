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
    ],
    targets: [
        // Everything but the entry point lives in BitampKit so tests can import it.
        .target(
            name: "BitampKit", dependencies: ["BitampAtomics", "BitampPakKit", "BitampPakProtocol"],
            // Core ML models, compiled when first used: Basic Pitch (see BasicPitch.swift)
            // and MSNet vocal (scripts/msnet/convert.py).
            resources: [.copy("Resources/BasicPitch"), .copy("Resources/MSNet")]),
        .target(name: "BitampAtomics"),
        // What an Expansion Pak sees of Bitamp: protocols and value types only. See docs/PAKS.md.
        .target(name: "BitampPakKit"),
        // Third-party Paks: the messages Bitamp and a Pak's program exchange, the Swift
        // library for writing one, and the demo Pak (packaged by scripts/make-pak.sh).
        .target(name: "BitampPakProtocol"),
        .target(name: "BitampPakSDK", dependencies: ["BitampPakProtocol"]),
        .executableTarget(name: "BitampDemoPak", dependencies: ["BitampPakSDK"], exclude: ["pak.json"]),
        // Expansion Paks built into Bitamp. Each depends on BitampPakKit only.
        .target(name: "BitampAppleMusicPak", dependencies: ["BitampPakKit"]),
        .executableTarget(name: "Bitamp", dependencies: ["BitampKit", "BitampAppleMusicPak"]),
        .testTarget(name: "BitampTests", dependencies: [
            "BitampKit", "BitampPakKit", "BitampAppleMusicPak", "BitampPakSDK", "BitampDemoPak",
        ]),
    ]
)
