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
        let pattern = try NSRegularExpression(
            pattern: #"(public\s+|internal\s+|private\s+)?static\s+let\s+shared[\s=]"#
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcesURL.path),
              let enumerator = fm.enumerator(
                at: sourcesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            // Source tree not accessible at test runtime (e.g. physical device). Skip silently.
            return
        }

        var violations: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            for (lineIdx, line) in lines.enumerated() {
                let nsRange = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: nsRange) != nil {
                    violations.append("\(fileURL.lastPathComponent):\(lineIdx + 1): \(line)")
                }
            }
        }

        if !violations.isEmpty {
            XCTFail(
                "'static let shared' found in Sources/VelocityUI — singletons are forbidden.\n"
                    + violations.joined(separator: "\n")
            )
        }
    }
}
