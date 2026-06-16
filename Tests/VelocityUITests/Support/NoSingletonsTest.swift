// NoSingletonsTest.swift

import XCTest
import Foundation

/// Locks the no-singletons rule in CI.
/// Any `static let shared` on a VelocityUI-owned type is a design violation — all
/// long-lived collaborators must live inside RenderEnvironment and be injected
/// by initializer. See CLAUDE.md Swift Conventions → Design Principles.
final class NoSingletonsTest: XCTestCase {

    func testNoStaticLetSharedInSources() throws {
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support/
            .deletingLastPathComponent()  // VelocityUITests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Sources")
            .appendingPathComponent("VelocityUI")

        // Regex matches declarations only: optional access modifier + "static let shared".
        // Does NOT match comments or prose containing "static let shared" as a substring.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [
            "-rnE", "--include=*.swift",
            "(public[[:space:]]+|internal[[:space:]]+|private[[:space:]]+)?static[[:space:]]+let[[:space:]]+shared[[:space:]=]",
            sourcesURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // grep exit code 1 means no matches (success). Exit code 0 means matches found.
        if process.terminationStatus == 0 {
            XCTFail("'static let shared' found in Sources/VelocityUI — singletons are forbidden.\n\(output)")
        }
    }
}
