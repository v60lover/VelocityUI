// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VelocityUI",
    platforms: [
        .iOS(.v17),
        // No macOS deployment target existed before VelocityUI-ry1v. FrozenBitmapStore uses
        // OSAllocatedUnfairLock (macOS 13+) and is intentionally NOT gated behind
        // `#if canImport(UIKit)` — it needs no UIKit, and the bead wants its tests runnable via
        // plain `swift test` on macOS without DeviceTestHost. Without an explicit macOS floor,
        // SwiftPM infers a very old default deployment target for the host-macOS build, and
        // OSAllocatedUnfairLock fails to compile. This does not change what the library ships
        // (product platform support is still iOS-only) — it only unblocks the macOS test host.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VelocityUI",
            targets: ["VelocityUI"]
        )
    ],
    // SPIKE VelocityUI-wmss.4.1: tree-sitter deps live on the TEST target only —
    // the VelocityUI product stays clean while we prove the iOS-device C build.
    // Remove (or promote into VelocityUI) once the highlighter decision lands.
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.0")
    ],
    targets: [
        .target(
            name: "VelocityUI",
            path: "Sources/VelocityUI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VelocityUITests",
            dependencies: [
                "VelocityUI",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json")
            ],
            path: "Tests/VelocityUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
