// LanguageIDFenceInfoTests.swift

import XCTest
@testable import VelocityUI

/// VelocityUI-yvjr: maps a fenced code block's raw fence-info string to a `LanguageID` grammar key.
final class LanguageIDFenceInfoTests: XCTestCase {
    func testRecognizedAliases_mapToExpectedLanguage() {
        let cases: [(String, LanguageID)] = [
            ("swift", .swift),
            ("Swift", .swift),
            ("js", .javascript),
            ("javascript", .javascript),
            ("jsx", .javascript),
            ("ts", .typescript),
            ("typescript", .typescript),
            ("tsx", .typescript),
            ("py", .python),
            ("python", .python),
            ("json", .json),
            ("bash", .bash),
            ("sh", .bash),
            ("shell", .bash),
            ("zsh", .bash),
            ("sql", .sql),
        ]
        for (fenceInfo, expected) in cases {
            XCTAssertEqual(LanguageID(fenceInfo: fenceInfo), expected, "fenceInfo \"\(fenceInfo)\" must map to \(expected)")
        }
    }

    func testNilFenceInfo_fallsBackToPlaintext() {
        XCTAssertEqual(LanguageID(fenceInfo: nil), .plaintext)
    }

    func testUnrecognizedFenceInfo_fallsBackToPlaintext_neverAnError() {
        XCTAssertEqual(LanguageID(fenceInfo: "brainfuck"), .plaintext)
        XCTAssertEqual(LanguageID(fenceInfo: ""), .plaintext)
    }
}
