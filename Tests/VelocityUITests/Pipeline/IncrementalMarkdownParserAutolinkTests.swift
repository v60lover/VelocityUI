// IncrementalMarkdownParserAutolinkTests.swift

import XCTest
@testable import VelocityUI

// Tests for autolinks and bare-URL linkification (VelocityUI-i1xx.5).
final class IncrementalMarkdownParserAutolinkTests: XCTestCase {
    // MARK: Angle-bracket autolinks

    func testAngleBracketHttpsUrl() {
        let runs = inlineRuns("<https://example.com>")
        XCTAssertEqual(runs.count, 1, "Should produce exactly one run")
        XCTAssertTrue(runs[0].style.contains(.link))
        XCTAssertEqual(runs[0].url, "https://example.com")
        XCTAssertEqual(runs[0].text, "https://example.com")
    }

    func testAngleBracketHttpUrl() {
        let runs = inlineRuns("<http://example.com>")
        XCTAssertEqual(runs.count, 1, "Should produce exactly one run")
        XCTAssertTrue(runs[0].style.contains(.link))
        XCTAssertEqual(runs[0].url, "http://example.com")
    }

    // MARK: Bare URLs

    func testBareUrlInProse() {
        let runs = inlineRuns("Check https://example.com here")
        XCTAssertEqual(runs.count, 3, "Should produce exactly three runs")

        XCTAssertEqual(runs[0].text, "Check ")
        XCTAssertFalse(runs[0].style.contains(.link))
        XCTAssertNil(runs[0].url)

        XCTAssertEqual(runs[1].text, "https://example.com")
        XCTAssertTrue(runs[1].style.contains(.link))
        XCTAssertEqual(runs[1].url, "https://example.com")

        XCTAssertEqual(runs[2].text, " here")
        XCTAssertFalse(runs[2].style.contains(.link))
        XCTAssertNil(runs[2].url)
    }

    func testBareUrlWithTrailingPunctuation() {
        let runs = inlineRuns("Visit https://example.com.")
        XCTAssertEqual(runs.count, 3, "Should produce exactly three runs")

        XCTAssertEqual(runs[0].text, "Visit ")
        XCTAssertFalse(runs[0].style.contains(.link))

        XCTAssertTrue(runs[1].style.contains(.link))
        XCTAssertEqual(runs[1].url, "https://example.com")
        XCTAssertEqual(runs[1].text, "https://example.com")

        XCTAssertEqual(runs[2].text, ".")
        XCTAssertFalse(runs[2].style.contains(.link))
        XCTAssertNil(runs[2].url)
    }

    func testBareUrlAtEnd() {
        let runs = inlineRuns("See https://example.com")
        let linkRun = runs.last
        XCTAssertNotNil(linkRun, "Should have at least one run")
        XCTAssertTrue(linkRun?.style.contains(.link) == true)
        XCTAssertEqual(linkRun?.url, "https://example.com")
    }

    // MARK: Edge cases and regression guards

    func testPlainTextWithoutLinks() {
        let runs = inlineRuns("no links here")
        XCTAssertEqual(runs.count, 1, "Should produce exactly one run")
        XCTAssertEqual(runs[0].text, "no links here")
        XCTAssertFalse(runs[0].style.contains(.link))
        XCTAssertNil(runs[0].url)
    }

    func testIncompleteStreamingUrl() {
        let runs = inlineRuns("check https://")
        XCTAssertEqual(runs.count, 1, "Should produce exactly one run")
        XCTAssertEqual(runs[0].text, "check https://")
        XCTAssertFalse(runs[0].style.contains(.link))
        XCTAssertNil(runs[0].url)
    }

    /// No closing '>' means this never becomes an angle-bracket autolink -- the '<' renders as
    /// a literal char. The "https://example.com" that follows it is still a valid bare URL
    /// though ('<' is not a word char, so the bare-URL word-boundary guard doesn't block it),
    /// so it links via that separate path -- two runs, not zero.
    func testUnclosedAngleBracketAutolink() {
        let runs = inlineRuns("<https://example.com")
        XCTAssertEqual(runs.count, 2, "Should produce a literal '<' run plus a bare-URL link run")
        XCTAssertEqual(runs[0].text, "<")
        XCTAssertFalse(runs[0].style.contains(.link))
        XCTAssertTrue(runs[1].style.contains(.link))
        XCTAssertEqual(runs[1].url, "https://example.com")
    }

    func testBareUrlDoesNotTriggerMidWord() {
        let runs = inlineRuns("xhttp://example.com")
        let hasLink = runs.contains { $0.style.contains(.link) }
        XCTAssertFalse(hasLink, "Should not produce any link runs for mid-word URL")
    }

    func testMarkdownLinkRegression() {
        let runs = inlineRuns("[click](https://example.com)")
        XCTAssertEqual(runs.count, 1, "Should produce exactly one run")
        XCTAssertEqual(runs[0].text, "click")
        XCTAssertEqual(runs[0].url, "https://example.com")
        XCTAssertTrue(runs[0].style.contains(.link))
    }
}
