// swift-tools-version:6.0
// BlurHashGenerator
//
// Offline, macOS-only dev tool (VelocityUI-9x0). Downloads BenchmarkDataset's per-item
// picsum.photos images by seed and encodes each into a REAL per-item BlurHash via
// VelocityUI's public encodeBlurHash(_:componentsX:componentsY:) — the same algorithm the
// on-device decode path (decodeBlurHashPlaceholder) consumes, so the demo's blur->image
// crossfade actually matches the photo underneath instead of a hand-picked sample. Emits a
// checked-in Swift source file (BenchmarkHost/Sources/PrecomputedBlurHashes.swift) so
// BenchmarkDataset.generate() stays synchronous / network-free / deterministic at benchmark
// run time — this tool is dev-time tooling only, never invoked from the app or CI benchmark
// runs themselves.

import PackageDescription

let package = Package(
    name: "BlurHashGenerator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "BlurHashGenerator",
            dependencies: ["VelocityUI"]
        )
    ]
)
