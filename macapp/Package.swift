// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CheongyakCal",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CheongyakCal", path: "Sources/CheongyakCal")
    ]
)
