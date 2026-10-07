// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bitamp",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything but the entry point lives in BitampKit so tests can import it.
        .target(
            name: "BitampKit", dependencies: ["BitampAtomics"],
            // Basic Pitch's Core ML model, compiled when first used (see BasicPitch.swift).
            resources: [.copy("Resources/BasicPitch")]),
        .target(name: "BitampAtomics"),
        .executableTarget(name: "Bitamp", dependencies: ["BitampKit"]),
        .testTarget(name: "BitampTests", dependencies: ["BitampKit"]),
    ]
)
