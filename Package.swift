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
    // VelocityUI-oz5q.3: tree-sitter is the highlighter engine (wmss.4 decision,
    // wmss.4.1 device-proven). v1 grammar set: swift, javascript, python, json, bash.
    // SQL is deferred — DerekStride/tree-sitter-sql's own Package.swift fails to resolve
    // under this toolchain (its test target references a dependency name that no longer
    // resolves), independent of anything in this manifest; see follow-up bead.
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.0"),
        // Pinned to exact commits, not semver ranges: current HEAD's Package.swift lists
        // scanner.c behind `if FileManager.default.fileExists(atPath: "src/scanner.c")`, which
        // evaluates against the ROOT package's directory when this manifest is loaded as a
        // dependency (not this package's own checkout) — the check silently returns false,
        // scanner.c never gets compiled, and the final link fails with undefined
        // `tree_sitter_javascript_external_scanner_*` / `..._python_..._*` symbols. These
        // revisions predate that pattern and list `src/scanner.c` unconditionally.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", revision: "a48cee89ea5a4866d8516ab344c1f4b35acf999f"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", revision: "d0535a4d241fe461d1f86885f7aaeb71064c86ba"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.23.0"),
        // Pinned to an exact tag, not a semver range: 0.7.3 proper does not ship a generated
        // `src/parser.c` (grammar.json needs `tree-sitter generate`, which the SPM build can't
        // run). "-with-generated-files" is alex-pinkus/tree-sitter-swift's own convention for a
        // tag that includes the generated C sources SPM actually needs to compile.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files")
    ],
    targets: [
        .target(
            name: "VelocityUI",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                "SwaTex",
                "SwaTexRender"
            ],
            path: "Sources/VelocityUI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // VelocityUI-gojy.6: forked from PhraseHQ/SwaTex (MIT) — pure-Swift LaTeX engine
        // (lexer -> parser -> layout -> display list). Replaces SwiftMath (gojy.1's original
        // pick), whose only render surface is a UIView (MTMathUILabel) — an architecture
        // violation once wired into the render pipeline (gojy.3). No platform dependencies.
        // See THIRD_PARTY_NOTICES.md for the local patches applied at vendor time.
        .target(
            name: "SwaTex",
            path: "Sources/SwaTex",
            exclude: ["LICENSE"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // CoreGraphics/CoreText rendering backend for SwaTex: draws a display list straight
        // into a CGContext/CGImage (DisplayListRenderer, ImageRenderer) — no UIView anywhere
        // in the path. Upstream's SwaTexView/MathView (UIKit/SwiftUI wrappers) are
        // intentionally not vendored; VelocityUI is CALayer-only.
        .target(
            name: "SwaTexRender",
            dependencies: ["SwaTex"],
            path: "Sources/SwaTexRender",
            resources: [
                .copy("Resources/Fonts")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // libz for FastPNGEncoder's level-1 deflate (stable C ABI, present on every
                // Apple platform).
                .linkedLibrary("z")
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
        ),
        // VelocityUI-gojy.6: a curated subset of upstream PhraseHQ/SwaTex's own
        // test suite, vendored alongside the source. Excludes every file that
        // exercises SwaTexView/MathView (UIKit/SwiftUI wrappers we don't vendor)
        // — see THIRD_PARTY_NOTICES.md for the full exclusion list.
        .testTarget(
            name: "SwaTexTests",
            dependencies: ["SwaTex"],
            path: "Tests/SwaTexTests",
            resources: [
                .copy("Resources/golden")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SwaTexRenderTests",
            dependencies: ["SwaTex", "SwaTexRender"],
            path: "Tests/SwaTexRenderTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
