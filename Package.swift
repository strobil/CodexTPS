// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CodexTPS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CodexTPS", path: "Sources/CodexTPS")
    ]
)
