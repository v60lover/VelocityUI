// TableColumnWidthSolverTests.swift

import XCTest
@testable import VelocityUI

final class TableColumnWidthSolverTests: XCTestCase {
    // MARK: - Acceptance criteria

    /// | Acceptance criterion | Assertion |
    /// |---|---|
    /// | 1 | Branch 1 (`availableWidth >= Σmax`): every column gets its natural `max` |
    /// | 2 | Branch 2, the doc's worked example (300 -> [70, 230]) |
    /// | 3 | A single-word column (`max == min`) never grows |
    /// | 4 | `Σ widths == availableWidth` in branch 2 |
    /// | 5 | Branch 3 (`availableWidth < Σmin`): keep natural `min` widths, `overflow == true` |
    /// | 6 | `overflow` is true ONLY in branch 3 |
    /// | 7 | Empty intrinsics doesn't crash |
    /// | 8 | `measureColumnIntrinsics`: `max` per column = each cell's natural width via injected `measure` |
    /// | 9 | `measureColumnIntrinsics`: `min` = widest SINGLE TOKEN in a multi-word cell |
    /// | 10 | The composed `solveColumnWidths(cells:availableWidth:measure:)` matches manual chain |

    // MARK: - Test 1: Branch 1 (availableWidth >= Σmax)

    func testSolveColumnWidthsBranch1EveryColumnGetMaxWidth() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),
            ColumnIntrinsics(min: 85, max: 260)
        ]
        let availableWidth: CGFloat = 330  // == Σmax (70 + 260)

        let result = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        XCTAssertEqual(result.widths[0], 70, accuracy: 0.0001)
        XCTAssertEqual(result.widths[1], 260, accuracy: 0.0001)
        XCTAssertFalse(result.overflow)
    }

    // MARK: - Test 2: Branch 2 (worked example from doc)

    func testSolveColumnWidthsBranch2WorkedExample() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),
            ColumnIntrinsics(min: 85, max: 260)
        ]
        let availableWidth: CGFloat = 300  // < Σmax (330), > Σmin (155)

        let result = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        XCTAssertEqual(result.widths[0], 70, accuracy: 0.0001)
        XCTAssertEqual(result.widths[1], 230, accuracy: 0.0001)
        XCTAssertFalse(result.overflow)
    }

    // MARK: - Test 3: Single-word column never grows

    func testSingleWordColumnNeverGrows() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),  // single-word: min == max
            ColumnIntrinsics(min: 85, max: 260)  // flexible column
        ]
        let availableWidth: CGFloat = 300

        let result = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        // Column 0 (single-word) must stay exactly at 70, not grow
        XCTAssertEqual(result.widths[0], 70, accuracy: 0.0001)
    }

    // MARK: - Test 4: Sum of widths equals availableWidth in Branch 2

    func testSumOfWidthsEqualsAvailableWidthBranch2() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),
            ColumnIntrinsics(min: 85, max: 260)
        ]
        let availableWidth: CGFloat = 300

        let result = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        let sumOfWidths = result.widths.reduce(0, +)
        XCTAssertEqual(sumOfWidths, availableWidth, accuracy: 0.0001)
    }

    // MARK: - Test 5: Branch 3 (availableWidth < Σmin)

    func testSolveColumnWidthsBranch3OverflowKeepsMinWidths() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),
            ColumnIntrinsics(min: 85, max: 260)
        ]
        let availableWidth: CGFloat = 100  // < Σmin (155)

        let result = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        XCTAssertEqual(result.widths[0], 70, accuracy: 0.0001)
        XCTAssertEqual(result.widths[1], 85, accuracy: 0.0001)
        XCTAssertTrue(result.overflow)
    }

    // MARK: - Test 6: Overflow flag correctness across all branches

    func testOverflowFlagCorrectness() {
        let intrinsics = [
            ColumnIntrinsics(min: 70, max: 70),
            ColumnIntrinsics(min: 85, max: 260)
        ]

        // Branch 1: availableWidth >= Σmax
        let result1 = solveColumnWidths(intrinsics: intrinsics, availableWidth: 330)
        XCTAssertFalse(result1.overflow, "Branch 1: overflow should be false")

        // Branch 2: Σmin <= availableWidth < Σmax
        let result2 = solveColumnWidths(intrinsics: intrinsics, availableWidth: 300)
        XCTAssertFalse(result2.overflow, "Branch 2: overflow should be false")

        // Branch 3: availableWidth < Σmin
        let result3 = solveColumnWidths(intrinsics: intrinsics, availableWidth: 100)
        XCTAssertTrue(result3.overflow, "Branch 3: overflow should be true")
    }

    // MARK: - Test 7: Empty intrinsics doesn't crash

    func testEmptyIntrinsicsNoOp() {
        let result = solveColumnWidths(intrinsics: [], availableWidth: 100)

        XCTAssertEqual(result.widths, [])
        XCTAssertFalse(result.overflow)
    }

    // MARK: - Test 8: measureColumnIntrinsics max per column

    func testMeasureColumnIntrinsicsMaxPerColumn() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            CGSize(width: CGFloat(descriptor.content.count) * 10, height: 20)
        }

        // 2x2 grid: row1 = ["cat", "elephant"], row2 = ["dog", "hi"]
        let cells: [[TextDescriptor]] = [
            [makeCell("cat"), makeCell("elephant")],
            [makeCell("dog"), makeCell("hi")]
        ]

        let noPadding = TableCellPadding(horizontal: 0, vertical: 0)
        let intrinsics = measureColumnIntrinsics(cells: cells, measure: fakeMeasure, padding: noPadding)

        // Column 0: max("cat"=30, "dog"=30) = 30 (+ the wrap guard, no padding here)
        XCTAssertEqual(intrinsics[0].max, 30 + columnInkWrapGuard, accuracy: 0.0001)
        // Column 1: max("elephant"=80, "hi"=20) = 80 (+ the wrap guard)
        XCTAssertEqual(intrinsics[1].max, 80 + columnInkWrapGuard, accuracy: 0.0001)
    }

    // MARK: - Test 9: measureColumnIntrinsics min is widest single token, not whole cell

    func testMeasureColumnIntrinsicsMinIsWidestToken() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            CGSize(width: CGFloat(descriptor.content.count) * 10, height: 20)
        }

        // Column 0: single-word "Alexander" (9 chars -> 90)
        // Column 1: multi-word "A very long sentence" (20 chars incl. spaces -> 200 whole
        // string, but the widest token "sentence" is 8 chars -> 80)
        let cells: [[TextDescriptor]] = [
            [makeCell("Alexander"), makeCell("A very long sentence")]
        ]

        let noPadding = TableCellPadding(horizontal: 0, vertical: 0)
        let intrinsics = measureColumnIntrinsics(cells: cells, measure: fakeMeasure, padding: noPadding)

        // Column 0 (single-word): min == max == 90 (+ wrap guard, no padding here)
        XCTAssertEqual(intrinsics[0].min, 90 + columnInkWrapGuard, accuracy: 0.0001)
        XCTAssertEqual(intrinsics[0].max, 90 + columnInkWrapGuard, accuracy: 0.0001)

        // Column 1 (multi-word): min = widest token ("sentence" = 80), max = whole (200), each + guard
        XCTAssertEqual(intrinsics[1].min, 80 + columnInkWrapGuard, accuracy: 0.0001)
        XCTAssertEqual(intrinsics[1].max, 200 + columnInkWrapGuard, accuracy: 0.0001)
        // Verify min < max (proves min is from token, not whole string)
        XCTAssertLessThan(intrinsics[1].min, intrinsics[1].max)
    }

    // MARK: - Test 10: Composed function matches manual chain

    func testComposedFunctionMatchesManualChain() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            CGSize(width: CGFloat(descriptor.content.count) * 10, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("foo"), makeCell("bar")]
        ]
        let availableWidth: CGFloat = 75

        // Composed function
        let composedResult = solveColumnWidths(
            cells: cells,
            availableWidth: availableWidth,
            measure: fakeMeasure
        )

        // Manual chain
        let intrinsics = measureColumnIntrinsics(cells: cells, measure: fakeMeasure)
        let manualResult = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        // Both should produce equal results
        XCTAssertEqual(composedResult.widths.count, manualResult.widths.count)
        for (composedWidth, manualWidth) in zip(composedResult.widths, manualResult.widths) {
            XCTAssertEqual(composedWidth, manualWidth, accuracy: 0.0001)
        }
        XCTAssertEqual(composedResult.overflow, manualResult.overflow)
    }

    // MARK: - Test 11: padding is reserved in both min and max

    func testMeasureColumnIntrinsicsIncludesHorizontalPadding() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            CGSize(width: CGFloat(descriptor.content.count) * 10, height: 20)
        }
        let cells: [[TextDescriptor]] = [[makeCell("hello")]]  // 5 chars -> natural 50
        let padding = TableCellPadding(horizontal: 8, vertical: 6)

        let intrinsics = measureColumnIntrinsics(cells: cells, measure: fakeMeasure, padding: padding)

        // Both bounds carry 2 * horizontal (16) + the wrap guard on top of the raw 50pt measurement.
        XCTAssertEqual(intrinsics[0].min, 50 + 16 + columnInkWrapGuard, accuracy: 0.0001)
        XCTAssertEqual(intrinsics[0].max, 50 + 16 + columnInkWrapGuard, accuracy: 0.0001)
    }

    // MARK: - Test 12: regression — header-width column doesn't wrap at natural width + padding

    /// Reproduces the padding-vs-width mismatch bug: column widths were solved WITHOUT padding
    /// but text was laid out WITH padding subtracted, squeezing every column 2*horizontal too
    /// narrow so text that fits on one line wrapped. With padding folded into the intrinsics the
    /// solved width reserves it back, so `layoutTableCells` re-measures at the full natural width
    /// and the header stays one line.
    func testHeaderColumnDoesNotWrapAtNaturalWidthPlusPadding() {
        // "Name" has a 40pt natural single-line width; below 40pt it wraps to two lines.
        let naturalWidth: CGFloat = 40
        let lineHeight: CGFloat = 20
        let wrappingMeasure: TextMeasure = { descriptor, width in
            if width >= naturalWidth {
                return CGSize(width: naturalWidth, height: lineHeight)
            }
            return CGSize(width: width, height: lineHeight * 2)  // wrapped
        }

        let cells: [[TextDescriptor]] = [[makeCell("Name")]]
        let padding = TableCellPadding.default  // horizontal 8, vertical 6

        // Plenty of room, so branch 1 hands each column its full max (natural + padding).
        let solution = solveColumnWidths(
            cells: cells, availableWidth: 1000, measure: wrappingMeasure, padding: padding
        )
        XCTAssertEqual(
            solution.widths[0], naturalWidth + 2 * padding.horizontal + columnInkWrapGuard, accuracy: 0.0001
        )

        let layout = layoutTableCells(
            cells: cells, columnWidths: solution.widths, alignments: [.none],
            measure: wrappingMeasure, padding: padding
        )

        // One line: content box == naturalWidth, so height is a single line + vertical padding.
        let rowHeight = layout.rows[0].frame.height
        XCTAssertEqual(rowHeight, lineHeight + 2 * padding.vertical, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func makeCell(_ content: String) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
    }
}
