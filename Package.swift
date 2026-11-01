// swift-tools-version: 6.2
import PackageDescription

// Sandglass is a macOS app. Its culling logic — pairing, flags, export, zoom and
// pan geometry, raw-preview parsing, caching — lives in `Sources/Sandglass/Core`
// and depends on nothing but Foundation, so on other platforms the package builds
// just that core and runs its tests. On a Mac you get the whole app.
#if os(macOS)
let targets: [Target] = [
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
#else
let targets: [Target] = [
    .target(
        name: "Sandglass",
        path: "Sources/Sandglass/Core"
    ),
    .testTarget(
        name: "SandglassTests",
        dependencies: ["Sandglass"],
        path: "Tests/SandglassTests",
        exclude: ["App"],
        sources: ["Core"]
    )
]
#endif

let package = Package(
    name: "Sandglass",
    platforms: [.macOS(.v26)],
    targets: targets
)
