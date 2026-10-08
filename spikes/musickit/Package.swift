// swift-tools-version:5.9
// A throwaway app that answers one question: can a Developer ID–signed Mac app play
// Apple Music through MusicKit's ApplicationMusicPlayer? See docs/PAKS.md.
import PackageDescription

let package = Package(
    name: "MusicKitSpike",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Bitamp", path: "../..")],
    targets: [.executableTarget(
        name: "MusicKitSpike",
        dependencies: [.product(name: "BitampAppleMusicPak", package: "Bitamp")])]
)
