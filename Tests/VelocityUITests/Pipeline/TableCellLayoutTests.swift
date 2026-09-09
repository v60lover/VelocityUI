// TableCellLayoutTests.swift

import XCTest
@testable import VelocityUI

final class TableCellLayoutTests: XCTestCase {
    // MARK: - Acceptance criteria

    /// | Acceptance criterion | Assertion |
    /// |---|---|
    /// | 1 | Row height = tallest wrapped cell + padding |
    /// | 2 | Header row gets bold weight, body rows don't |
    /// | 3 | Left alignment flushes text to cell's left padding edge |
    /// | 4 | Center alignment centers the leftover slack |
    /// | 5 | Right alignment flushes text to cell's right padding edge |
    /// | 6 | Wrapped cell grows row height past plain sibling |
    /// | 7 | Layout uses fixed column widths verbatim |
    /// | 8 | No colspan/rowspan — 2x2 grid has 2 rows of 2 cells |

    // MARK: - Test 1: Row height = tallest wrapped cell + padding

    func testRowHeightEqualsMaxCellHeightPlusPadding() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            switch descriptor.content {
            case "tall": return CGSize(width: 40, height: 50)
            default: return CGSize(width: 40, height: 20)
            }
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("short"), makeCell("tall")]
        ]
        let columnWidths: [CGFloat] = [100, 100]
        let alignments: [TableColumnAlignment] = [.left, .left]
        let padding = TableCellPadding.default

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure,
            padding: padding
        )

        let expectedHeight = 50 + 2 * padding.vertical
        XCTAssertEqual(layout.rows[0].frame.height, expectedHeight, accuracy: 0.0001)
    }

    // MARK: - Test 2: Header row gets bold weight, body rows don't

    func testHeaderRowGetsBoldWeight() {
        let font = VFontDescriptor(size: 16, weight: VFontDescriptor.regularWeight)
        let color = VColorDescriptor.primary

        let tableRows: [[TableCell]] = [
            [TableCell(text: "Name", runs: [])],
            [TableCell(text: "Alice", runs: [])]
        ]

        let descriptors = makeTableCellDescriptors(tableRows: tableRows, font: font, color: color)

        // Header row (index 0) should have bold weight
        XCTAssertEqual(descriptors[0][0].font.weight, VFontDescriptor.boldWeight)
        // Body row (index 1) should have the input font weight
        XCTAssertEqual(descriptors[1][0].font.weight, VFontDescriptor.regularWeight)
    }

    // MARK: - Test 2b: `**bold**` cell strips markers and bolds the whole word

    /// Regression: a `**bold**` table cell must render its content WITHOUT the literal `**`
    /// markers, and the bold run must cover the entire word — not stop short, leaving the last
    /// characters unstyled. The bug: `content` used the raw `cell.text` (`"**Eviction metric**"`)
    /// while `runs` were tokenized from the stripped text, so the bold run (length 15) applied to
    /// the first 15 UTF-16 units of a 19-unit string, unstyling the `ic**` tail.
    func testBoldCellStripsMarkersAndBoldsWholeWord() {
        let font = VFontDescriptor(size: 16, weight: VFontDescriptor.regularWeight)

        let raw = "**Eviction metric**"
        let tableRows: [[TableCell]] = [
            [TableCell(text: raw, runs: inlineRuns(raw))]
        ]

        let descriptors = makeTableCellDescriptors(tableRows: tableRows, font: font)
        let descriptor = descriptors[0][0]

        // Content has no literal markers.
        XCTAssertEqual(descriptor.content, "Eviction metric")
        XCTAssertFalse(descriptor.content.contains("*"))

        // The run lengths cover exactly the content — nothing left over to fall back to base style.
        let totalRunLength = descriptor.runs.reduce(0) { $0 + $1.length }
        XCTAssertEqual(totalRunLength, descriptor.content.utf16.count)

        // Every run carries the bold weight (the whole word is emphasized, no unstyled tail).
        for run in descriptor.runs {
            XCTAssertEqual(run.font.weight, VFontDescriptor.boldWeight)
        }
    }

    // MARK: - Test 3: Left alignment flushes text to cell's left padding edge

    func testLeftAlignmentFlushesTextLeft() {
        let fakeMeasure: TextMeasure = { _, _ in
            CGSize(width: 30, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("text")]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]
        let padding = TableCellPadding.default

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure,
            padding: padding
        )

        let cell = layout.rows[0].cells[0]
        let expectedTextMinX = cell.frame.minX + padding.horizontal
        XCTAssertEqual(cell.textFrame.minX, expectedTextMinX, accuracy: 0.0001)
    }

    // MARK: - Test 4: Center alignment centers the leftover slack

    func testCenterAlignmentCentersSlack() {
        let fakeMeasure: TextMeasure = { _, _ in
            CGSize(width: 30, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("text")]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.center]
        let padding = TableCellPadding.default

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure,
            padding: padding
        )

        let cell = layout.rows[0].cells[0]
        // Content width = 100 - 2*8 = 84
        // Slack = 84 - 30 = 54
        // textFrame.minX = cell.frame.minX + 8 + 54/2 = cell.frame.minX + 35
        let expectedTextMinX = cell.frame.minX + 35
        XCTAssertEqual(cell.textFrame.minX, expectedTextMinX, accuracy: 0.0001)
    }

    // MARK: - Test 5: Right alignment flushes text to cell's right padding edge

    func testRightAlignmentFlushesTextRight() {
        let fakeMeasure: TextMeasure = { _, _ in
            CGSize(width: 30, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("text")]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.right]
        let padding = TableCellPadding.default

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure,
            padding: padding
        )

        let cell = layout.rows[0].cells[0]
        let expectedTextMaxX = cell.frame.maxX - padding.horizontal
        XCTAssertEqual(cell.textFrame.maxX, expectedTextMaxX, accuracy: 0.0001)
    }

    // MARK: - Test 6: Wrapped cell grows row height past plain sibling

    func testWrappedCellGrowsRowHeightPastPlainSibling() {
        let fakeMeasure: TextMeasure = { descriptor, _ in
            switch descriptor.content {
            case "prose": return CGSize(width: 90, height: 40)
            default: return CGSize(width: 40, height: 20)
            }
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("plain"), makeCell("prose")]
        ]
        let columnWidths: [CGFloat] = [100, 100]
        let alignments: [TableColumnAlignment] = [.left, .left]
        let padding = TableCellPadding.default

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure,
            padding: padding
        )

        // Row should grow to wrapped cell's height (40 + 2*6 = 52), not plain cell's (20 + 12 = 32)
        let expectedHeight = 40 + 2 * padding.vertical
        XCTAssertEqual(layout.rows[0].frame.height, expectedHeight, accuracy: 0.0001)
    }

    // MARK: - Test 7: Layout uses fixed column widths verbatim

    func testLayoutUsesFixedColumnWidthsVerbatim() {
        let fakeMeasure: TextMeasure = { _, _ in
            CGSize(width: 20, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("a"), makeCell("b")]
        ]
        let columnWidths: [CGFloat] = [100, 200]
        let alignments: [TableColumnAlignment] = [.left, .left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure
        )

        // Layout should use the exact column widths passed in
        XCTAssertEqual(layout.columnWidths, [100, 200])
        XCTAssertEqual(layout.rows[0].cells[0].frame.width, 100, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[0].cells[1].frame.width, 200, accuracy: 0.0001)
    }

    // MARK: - Test 8: 2x2 grid has 2 rows of 2 cells each

    func testNoColspanRowspan2x2GridHas2RowsOf2Cells() {
        let fakeMeasure: TextMeasure = { _, _ in
            CGSize(width: 20, height: 20)
        }

        let cells: [[TextDescriptor]] = [
            [makeCell("a"), makeCell("b")],
            [makeCell("c"), makeCell("d")]
        ]
        let columnWidths: [CGFloat] = [50, 60]
        let alignments: [TableColumnAlignment] = [.left, .left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: fakeMeasure
        )

        // Verify structure
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].cells.count, 2)
        XCTAssertEqual(layout.rows[1].cells.count, 2)

        // Verify cell widths match column widths
        XCTAssertEqual(layout.rows[0].cells[0].frame.width, 50, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[0].cells[1].frame.width, 60, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[1].cells[0].frame.width, 50, accuracy: 0.0001)
        XCTAssertEqual(layout.rows[1].cells[1].frame.width, 60, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func makeCell(_ content: String) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 16, weight: VFontDescriptor.regularWeight),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
    }
}
