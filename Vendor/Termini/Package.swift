// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Termini",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Termini",
            targets: ["Termini"]
        )
    ],
    targets: [
        // Same release Termini itself pins (arach/TermBridgeKit 0.1.6).
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/arach/TermBridgeKit/releases/download/0.1.6/GhosttyKit.xcframework.zip",
            checksum: "7265c68e6e2120d8e3ed9bd9299177f6de9312fde492f7923e2af67b23ba1339"
        ),
        .target(
            name: "Termini",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal")
            ]
        )
    ]
)
