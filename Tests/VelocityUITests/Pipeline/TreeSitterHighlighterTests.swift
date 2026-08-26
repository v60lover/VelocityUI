// TreeSitterHighlighterTests.swift

import XCTest
@testable import VelocityUI

/// VelocityUI-oz5q.3 acceptance criteria, traced to assertions:
///
/// | Invariant                                                        | Assertion |
/// |-------------------------------------------------------------------|-----------|
/// | colorRuns is pure: same (lines, grammar, theme) in -> same out    | testDeterministic_sameInputsProduceEqualOutput |
/// | Highlights swift/js/python/json/bash                              | testSwift/testJavaScript/testPython/testJSON/testBash — each asserts a specific token's exact range + TokenType |
/// | Unknown language -> empty runs, never throws                      | testPlaintext_producesEmptyRuns, testUnwiredLanguage_fallsBackToEmptyRuns (.typescript/.sql) |
final class TreeSitterHighlighterTests: XCTestCase {
    private let highlighter = TreeSitterHighlighter()
    private let registry = HighlightRegistry()

    private func run(_ lines: [String], _ languageID: LanguageID) -> [LineColorRuns] {
        let grammar = registry.grammar(for: languageID)
        return highlighter.colorRuns(for: lines[...], grammar: grammar, theme: .defaultLight)
    }

    private func assertContains(
        _ lineRuns: LineColorRuns,
        range: Range<Int>,
        tokenType: TokenType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            lineRuns.runs.contains { $0.range == range && $0.tokenType == tokenType },
            "expected a \(tokenType) run at \(range), got \(lineRuns.runs)",
            file: file,
            line: line
        )
    }

    // MARK: - Purity

    func testDeterministic_sameInputsProduceEqualOutput() {
        let lines = ["let x = 42", "// hi"]
        let grammar = registry.grammar(for: .swift)
        let first = highlighter.colorRuns(for: lines[...], grammar: grammar, theme: .defaultLight)
        let second = highlighter.colorRuns(for: lines[...], grammar: grammar, theme: .defaultLight)
        XCTAssertEqual(first, second)
    }

    // MARK: - Per-language highlighting

    func testSwift() {
        let result = run(["let x = 42", "// hi"], .swift)
        XCTAssertEqual(result.count, 2)
        assertContains(result[0], range: 0..<3, tokenType: .keyword)   // "let"
        assertContains(result[0], range: 8..<10, tokenType: .number)   // "42"
        assertContains(result[1], range: 0..<5, tokenType: .comment)   // "// hi"
    }

    func testJavaScript() {
        let result = run(["const a = \"hi\";", "// comment"], .javascript)
        XCTAssertEqual(result.count, 2)
        assertContains(result[0], range: 0..<5, tokenType: .keyword)    // "const"
        assertContains(result[0], range: 10..<14, tokenType: .string)  // "\"hi\""
        assertContains(result[1], range: 0..<10, tokenType: .comment)  // "// comment"
    }

    func testPython() {
        let result = run(["def foo():", "    return 1"], .python)
        XCTAssertEqual(result.count, 2)
        assertContains(result[0], range: 0..<3, tokenType: .keyword)    // "def"
        assertContains(result[0], range: 4..<7, tokenType: .function)  // "foo"
        assertContains(result[1], range: 4..<10, tokenType: .keyword)  // "return"
        assertContains(result[1], range: 11..<12, tokenType: .number) // "1"
    }

    func testJSON() {
        let result = run(["{\"a\": 1}"], .json)
        XCTAssertEqual(result.count, 1)
        assertContains(result[0], range: 1..<4, tokenType: .string)  // "\"a\""
        assertContains(result[0], range: 6..<7, tokenType: .number) // "1"
    }

    func testBash() {
        let result = run(["echo hi", "# comment"], .bash)
        XCTAssertEqual(result.count, 2)
        assertContains(result[0], range: 0..<4, tokenType: .function) // "echo"
        assertContains(result[1], range: 0..<9, tokenType: .comment)  // "# comment"
    }

    // MARK: - Fallback: never throws, always empty runs

    func testPlaintext_producesEmptyRuns() {
        let result = run(["anything at all"], .plaintext)
        XCTAssertEqual(result, [LineColorRuns(runs: [])])
    }

    func testUnwiredLanguage_fallsBackToEmptyRuns() {
        for languageID: LanguageID in [.typescript, .sql] {
            let result = run(["select * from t;"], languageID)
            XCTAssertEqual(result, [LineColorRuns(runs: [])], "\(languageID) has no grammar wired up yet")
        }
    }

    func testEmptyLines_producesEmptyArray() {
        XCTAssertEqual(run([], .swift), [])
    }
}
