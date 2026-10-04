// swift-tools-version: 5.9
import PackageDescription

// Targets:
//   PeekCore      — pure logic (parsers, waveform, metadata). No AppKit.
//   PeekUI        — shared SwiftUI preview surface (used by BOTH the
//                   Quick Look extension and the host app's Open…
//                   fallback, so the two always render identically).
//   PeekExtension — Quick Look preview extension principal class.
//                   Compiled into UTUVOPeekPreview.appex by
//                   scripts/build.sh (SwiftPM cannot emit .appex
//                   bundles); entry point is Foundation's
//                   NSExtensionMain via -Xlinker -e.
//   PeekApp       — host app executable (normal window, Open…
//                   fallback, --smoke-test).
let package = Package(
    name: "UTUVOPeek",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PeekCore", targets: ["PeekCore"]),
        .library(name: "PeekUI", targets: ["PeekUI"]),
        .executable(name: "PeekHost", targets: ["PeekApp"])
    ],
    targets: [
        .target(
            name: "PeekCore",
            path: "Sources/PeekCore"
        ),
        .target(
            name: "PeekUI",
            dependencies: ["PeekCore"],
            path: "Sources/PeekUI"
        ),
        .target(
            name: "PeekExtension",
            dependencies: ["PeekUI"],
            path: "Sources/PeekExtension"
        ),
        .executableTarget(
            name: "PeekApp",
            dependencies: ["PeekUI"],
            path: "Sources/PeekApp"
        ),
        .testTarget(
            name: "PeekCoreTests",
            dependencies: ["PeekCore", "PeekUI", "PeekExtension"],
            path: "Tests/PeekCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
