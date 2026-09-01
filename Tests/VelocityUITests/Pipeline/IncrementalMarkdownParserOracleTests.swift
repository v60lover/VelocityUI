// IncrementalMarkdownParserOracleTests.swift

import XCTest
@testable import VelocityUI

/// Differential tests for VelocityUI-snu1: borrow cmark-gfm's (via swift-markdown, test-target
/// only — see Package.swift) correctness on GFM tables as an oracle for
/// `IncrementalMarkdownParser`, without adopting it at runtime. See HYBRID_PARSER_SPIKE.md
/// section 4 for the GO/NO-GO rationale and `MarkdownOracle.swift` for the shared projection.
final class IncrementalMarkdownParserOracleTests: XCTestCase {

    // MARK: - Well-formed corpus: oracle agrees

    func testOracleAgrees_TwoColumnTable() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n\n"
        let result = compareTable(source: source)
        XCTAssertTrue(result.matches, result.diff ?? "")
    }

    func testOracleAgrees_ThreeColumnMultiRowTable() {
        let source = """
        | Name | Role | Score |
        |---|---|---|
        | Ann | Lead | 9 |
        | Bo | Eng | 7 |

        """
        let result = compareTable(source: source)
        XCTAssertTrue(result.matches, result.diff ?? "")
    }

    func testOracleAgrees_MixedColumnAlignment() {
        let source = "| L | C | R |\n|:---|:---:|---:|\n| x | y | z |\n\n"
        let result = compareTable(source: source)
        XCTAssertTrue(result.matches, result.diff ?? "")
    }

    // MARK: - Malformed corpus: the oracle has teeth

    /// A body row with fewer cells than the header. Per GFM's spec (Table.swift:18, "sibling
    /// rows will be expanded with empty cells to fit larger incoming rows"), cmark pads the
    /// short row so every row has the header's column count. Our raw parser does no such
    /// padding — it only splits whatever pipes are literally on the line — so the two sides
    /// disagree on `bodyRows[0].count`. This proves the oracle actually catches a real gap
    /// instead of vacuously agreeing on everything.
    func testOracleCatchesRaggedRow_FewerCellsThanHeader() {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |\n\n"
        let result = compareTable(source: source)
        XCTAssertFalse(result.matches, "a ragged row that our parser mishandles must not silently pass the oracle")
        XCTAssertNotNil(result.diff)
    }
}
