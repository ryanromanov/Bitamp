// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bitamp",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything but the entry point lives in BitampKit so tests can import it.
        .target(
            name: "BitampKit", dependencies: ["BitampAtomics"],
            // Core ML models, compiled when first used: Basic Pitch (see BasicPitch.swift)
            // and MSNet vocal (scripts/msnet/convert.py).
            resources: [.copy("Resources/BasicPitch"), .copy("Resources/MSNet")]),
        .target(name: "BitampAtomics"),
        .executableTarget(name: "Bitamp", dependencies: ["BitampKit"]),
        .testTarget(name: "BitampTests", dependencies: ["BitampKit"]),
    ]
)
