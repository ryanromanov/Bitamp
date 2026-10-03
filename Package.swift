// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bitamp",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything but the entry point lives in BitampKit so tests can import it.
        .target(name: "BitampKit"),
        .executableTarget(name: "Bitamp", dependencies: ["BitampKit"]),
        .testTarget(name: "BitampTests", dependencies: ["BitampKit"]),
    ]
)
