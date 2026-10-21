// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Visor"),
        .executableTarget(name: "VisorMedia"),
    ]
)
