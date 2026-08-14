// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacOSMessagesMCP",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MacOSMessagesMCPCore"
        ),
        .executableTarget(
            name: "MacOSMessagesMCP",
            dependencies: ["MacOSMessagesMCPCore"]
        ),
        .executableTarget(
            name: "MacOSMessagesMCPProxy",
            dependencies: ["MacOSMessagesMCPCore"]
        ),
        .executableTarget(
            name: "MacOSMessagesMCPTests",
            dependencies: ["MacOSMessagesMCPCore"],
            path: "Tests/MacOSMessagesMCPCoreTests"
        ),
    ]
)
