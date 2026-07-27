// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExeDesktopApp",
    platforms: [
        // Termini's floor, which is libghostty's.
        .macOS(.v14)
    ],
    dependencies: [
        // libghostty, wrapped as a SwiftUI surface. Pinned to a revision rather
        // than a version: the embedding APIs this app uses — per-surface
        // appearance config and the render-visibility gate that lets background
        // tabs stay warm without drawing — landed after the only release tag.
        .package(
            url: "https://github.com/arach/Termini.git",
            revision: "5fe5375dc7742fc436a5c03583e17c9a64afb6e2"
        )
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
