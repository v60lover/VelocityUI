// StreamFixturesTests.swift

import XCTest
@testable import BenchmarkHost

final class StreamFixturesTests: XCTestCase {

    func testTableFixtureIsDeterministic() {
        XCTAssertEqual(
            StreamFixture.table(rows: 50, widths: .changing(growEvery: 10)),
            StreamFixture.table(rows: 50, widths: .changing(growEvery: 10))
        )
    }

    func testTableRowEndIndicesMatchRowCountAndLandOnNewlines() {
        let fixture = StreamFixture.table(rows: 501, widths: .stable)
        XCTAssertEqual(fixture.rowEndTokenIndices.count, 501)
        for index in fixture.rowEndTokenIndices {
            XCTAssertTrue(fixture.tokens[index].hasSuffix("|\n"), "row must end on its closing pipe")
        }
    }

    func testStableWidthsNeverProduceAWiderCellThanTheFirstRows() {
        let fixture = StreamFixture.table(rows: 1000, widths: .stable)
        let longest = fixture.tokens.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(longest, "| 99.9 ms |\n".count + 2)
    }

    func testChangingWidthsGrowTheLatencyCellAtTheRequestedCadence() {
        let fixture = StreamFixture.table(rows: 100, widths: .changing(growEvery: 25))
        let wide = fixture.tokens.filter { $0.contains("retried") }
        XCTAssertEqual(wide.count, 3, "rows 25, 50, 75 grow the column")
        XCTAssertLessThan(wide[0].count, wide[2].count, "each growth step must be wider than the last")
    }

    func testLongParagraphHasNoBlankLineUntilTheEnd() {
        let fixture = StreamFixture.longParagraph(words: 400)
        let joined = fixture.tokens.joined()
        XCTAssertEqual(joined.components(separatedBy: "\n\n").count, 2, "one blank line, at the very end")
        XCTAssertTrue(joined.hasSuffix("\n\n"))
    }

    func testLongCodeKeepsTheFenceOpenForEveryLine() {
        let fixture = StreamFixture.longCode(lines: 300)
        XCTAssertEqual(fixture.tokens.first, "```swift\n")
        XCTAssertEqual(fixture.tokens.dropFirst().dropLast().count, 300)
        XCTAssertEqual(fixture.tokens.last, "```\n\n")
    }

    func testManyMessagesReturnsOneChunkListPerTurn() {
        let turns = StreamFixture.manyMessages(count: 40)
        XCTAssertEqual(turns.count, 40)
        XCTAssertTrue(turns.allSatisfy { !$0.isEmpty })
    }
}
