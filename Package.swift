// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExeDesktopApp",
    platforms: [
        // Termini's floor, which is libghostty's.
        .macOS(.v14)
    ],
    dependencies: [
        // libghostty, wrapped as a SwiftUI surface. Vendored locally (see
        // Vendor/Termini/README.md) rather than pulled from arach/Termini,
        // so we can carry a fix to its clipboard-write callback.
        .package(path: "Vendor/Termini")
    ],
    targets: [
        .executableTarget(
            name: "ExeDesktopApp",
            dependencies: [.product(name: "Termini", package: "Termini")],
            path: "Sources"
        ),
        // Covers the pure logic — names, quoting, the bootstrap script, config
        // decoding. Needs macOS: the app target imports AppKit/SwiftUI.
        .testTarget(
            name: "ExeDesktopAppTests",
            dependencies: ["ExeDesktopApp"],
            path: "Tests/ExeDesktopAppTests"
        )
    ]
)
