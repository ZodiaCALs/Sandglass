// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sandglass",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Sandglass",
            path: "Sources/Sandglass"
        ),
        .testTarget(
            name: "SandglassTests",
            dependencies: ["Sandglass"],
            path: "Tests/SandglassTests"
        )
    ]
)
