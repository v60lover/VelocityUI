// swift-tools-version:5.9
// BenchmarkReporter
//
// Reads a directory of per-run BenchmarkHost JSON reports and emits two files
// to the same directory: report.csv and report.md. The Markdown report is
// grouped by question (engine cost / real-world feel / cold launch / steady
// state / contract) — never by some flat runtime list — so readers cannot
// accidentally average across asymmetries.

import PackageDescription

let package = Package(
    name: "BenchmarkReporter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BenchmarkReporter",
            dependencies: ["BenchmarkReporterCore"]
        ),
        .target(name: "BenchmarkReporterCore"),
        .testTarget(
            name: "BenchmarkReporterCoreTests",
            dependencies: ["BenchmarkReporterCore"]
        ),
    ]
)
