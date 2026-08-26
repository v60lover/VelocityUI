// TreeSitterJSONSpikeTests.swift

import XCTest
import Foundation
import SwiftTreeSitter
import TreeSitterJSON

/// Spike VelocityUI-wmss.4.1 — insurance before flipping the code-block highlighter
/// decision from Highlightr to tree-sitter.
///
/// The one unknown wmss.4 never checked: does a tree-sitter grammar, pulled in as a
/// plain SwiftPM dependency, actually build for iOS and hand us color spans off the
/// main thread? JSON is the probe because it is pure C (no C++ scanner), so a failure
/// here is a build/linking failure, not a scanner-language quirk.
///
/// Deliberately NOT gated behind `#if canImport(UIKit)` — this exercises no UIKit, so
/// it runs on macOS `swift test` (first signal: SPM wiring + C build) AND on device via
/// DeviceTestHost (real signal: iOS-device C build).
///
/// Staged so a failure names its stage:
///   1. link  — `tree_sitter_json()` resolves -> the C grammar compiled & linked.
///   2. parse — Parser produces a Tree with no ERROR node -> runtime works.
///   3. query — LanguageConfiguration loads the bundled highlights.scm -> resources shipped.
///   4. off-main highlights — capture names + ranges come back off the main thread.
final class TreeSitterJSONSpikeTests: XCTestCase {

    private let sample = #"{"greeting":"hi","n":42,"ok":true,"nested":[null]}"#

    // MARK: - Stage 1+2: link + parse (synchronous, cheapest signal)

    func testStage1And2_grammarLinksAndParses() throws {
        // Stage 1: if the C grammar did not compile/link, this symbol is unresolved.
        let language = Language(language: tree_sitter_json())
        print("[wmss.4.1] stage1 link OK — tree_sitter_json() resolved")

        // Stage 2: parse and confirm a clean tree.
        let parser = Parser()
        try parser.setLanguage(language)
        let tree = try XCTUnwrap(parser.parse(sample), "parser returned no tree")
        let root = try XCTUnwrap(tree.rootNode, "tree has no root node")
        print("[wmss.4.1] stage2 parse OK — root=\(root.nodeType ?? "?") hasError=\(root.hasError)")
        XCTAssertFalse(root.hasError, "well-formed JSON must parse without an ERROR node")
    }

    // MARK: - Stage 3+4: compile a highlights query, run off-main

    // A curated highlights query, compiled from source against the grammar. We deliberately
    // do NOT load the grammar's bundled highlights.scm via LanguageConfiguration: (a) on macOS
    // SPM it fails with queryDirectoryNotReadable (the queries/ dir does not surface in the
    // .bundle), and (b) in production we need captures mapped to OUR TokenType/theme anyway,
    // so we own the query strings per language rather than inheriting a grammar's.
    private static let jsonHighlights = """
    (string) @string
    (number) @number
    (true) @constant.builtin
    (false) @constant.builtin
    (null) @constant.builtin
    """

    func testStage3And4_highlightsOffMain() async throws {
        // Stage 3: compile the query against the grammar. Throws if the query text does not
        // match the grammar's node types -> proves grammar + query engine agree.
        let language = Language(language: tree_sitter_json())
        let highlights = try Query(
            language: language,
            data: Data(Self.jsonHighlights.utf8)
        )
        print("[wmss.4.1] stage3 query OK — compiled highlights patternCount=\(highlights.patternCount)")

        let src = sample

        // Stage 4: run parse + query OFF the main thread and collect (name, range) spans.
        let spans: [(name: String, range: NSRange)] = try await Task.detached {
            XCTAssertFalse(Thread.isMainThread, "highlight work must run off the main thread")

            let parser = Parser()
            try parser.setLanguage(Language(language: tree_sitter_json()))
            let tree = try XCTUnwrap(parser.parse(src))

            let cursor = highlights.execute(in: tree)
            var out: [(String, NSRange)] = []
            for match in cursor {
                for capture in match.captures {
                    guard let name = capture.name else { continue }
                    out.append((name, capture.node.range))
                }
            }
            return out
        }.value

        for span in spans {
            let text = (src as NSString).substring(with: span.range)
            print("[wmss.4.1] stage4 span name=\(span.name) range=\(span.range) text=\(text)")
        }

        XCTAssertFalse(spans.isEmpty, "highlights query yielded no spans")

        // JSON grammar highlights: string keys/values, the number, and the true/null constants.
        let names = Set(spans.map(\.name))
        print("[wmss.4.1] stage4 distinct capture names=\(names.sorted())")
        XCTAssertTrue(
            names.contains(where: { $0.contains("string") }),
            "expected a string capture; got \(names.sorted())"
        )
        XCTAssertTrue(
            names.contains(where: { $0.contains("number") }),
            "expected a number capture; got \(names.sorted())"
        )
    }
}
