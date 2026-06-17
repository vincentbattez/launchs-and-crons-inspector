// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchInspector",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchInspector",
            path: "Sources/LaunchInspector"
        )
    ]
)
