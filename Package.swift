// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExeDesktopApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ExeDesktopApp",
            dependencies: ["SwiftTerm"],
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
