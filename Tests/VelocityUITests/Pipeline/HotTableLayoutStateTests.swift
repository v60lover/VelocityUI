// HotTableLayoutStateTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class HotTableLayoutStateTests: XCTestCase {
    private final class MeasureCounts {
        var values: [String: Int] = [:]
    }

    func testStableWidthAppendMeasuresOnlyNewRowAndMatchesFreshLayout() {
        let existing = (0..<500).map { [makeCell("row-\($0)")] }
        let appended = [[makeCell("OK")]]
        let state = HotTableLayoutState()
        let counts = MeasureCounts()
        let measure = countingMeasure(counts)

        let initial = state.resolve(
            cells: existing, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )
        counts.values.removeAll()

        let retained = state.resolve(
            cells: existing + appended, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )

        XCTAssertEqual(counts.values.count, 1, "only the appended descriptor should be measured")
        XCTAssertEqual(counts.values["OK"], 2, "the new row is measured once for layout and once for intrinsics")
        XCTAssertEqual(retained.rows.count, 501)
        XCTAssertEqual(retained.rows.prefix(500).map { $0.frame }, initial.rows.map { $0.frame })

        let fresh = freshLayout(existing + appended)
        assertLayoutsEqual(retained, fresh)
    }

    func testWidthChangingAppendRemeasuresOldRowsAndMatchesFreshLayout() {
        let existing = (0..<20).map { [makeCell("row-\($0)")] }
        let appended = [[makeCell(String(repeating: "W", count: 80))]]
        let state = HotTableLayoutState()
        let counts = MeasureCounts()
        let measure = countingMeasure(counts)

        let initial = state.resolve(
            cells: existing, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )
        counts.values.removeAll()

        let retained = state.resolve(
            cells: existing + appended, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )

        XCTAssertEqual(retained.columnWidths[0], 80 * 5 + 2 * TableCellPadding.default.horizontal + columnInkWrapGuard)
        XCTAssertNotEqual(retained.columnWidths, initial.columnWidths)
        for row in existing {
            XCTAssertGreaterThan(counts.values[row[0].content, default: 0], 0, "width change must remeasure \(row[0].content)")
        }

        assertLayoutsEqual(retained, freshLayout(existing + appended))
    }

    func testChangedPrefixFallsBackToFullLayout() {
        let original = (0..<12).map { [makeCell("row-\($0)")] }
        let state = HotTableLayoutState()
        let counts = MeasureCounts()
        let measure = countingMeasure(counts)

        _ = state.resolve(
            cells: original, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )
        counts.values.removeAll()
        let changed = [[makeCell("changed-header")]] + Array(original.dropFirst()) + [[makeCell("OK")]]

        let resolved = state.resolve(
            cells: changed, availableWidth: 10_000, alignments: [.left], measure: measure,
            padding: .default
        )

        XCTAssertGreaterThan(counts.values["changed-header", default: 0], 0)
        for row in original.dropFirst() {
            XCTAssertGreaterThan(counts.values[row[0].content, default: 0], 0, "prefix mutation must invalidate retained rows")
        }
        assertLayoutsEqual(resolved, freshLayout(changed))
    }

    func testWidthChangingAppendKeepsFullRasterSizeEqualToFreshRender() {
        let initialCells = [[makeCell("header")], [makeCell("row")]]
        let appendedCells = initialCells + [[makeCell(String(repeating: "W", count: 80))]]
        let key = BlockKey(itemID: "message", index: 0)
        let retainedState = HotTableLayoutState()

        XCTAssertNotNil(rasterizeHotTable(snapshot(initialCells, key: key), state: retainedState, formulaCache: nil, fontProvider: nil))
        let retained = rasterizeHotTable(
            snapshot(appendedCells, key: key), state: retainedState, formulaCache: nil, fontProvider: nil
        )
        let fresh = rasterizeHotTable(
            snapshot(appendedCells, key: key), state: HotTableLayoutState(), formulaCache: nil, fontProvider: nil
        )

        XCTAssertEqual(retained?.size, fresh?.size)
        XCTAssertEqual(retained?.image.width, fresh?.image.width)
        XCTAssertEqual(retained?.image.height, fresh?.image.height)
    }

    private func freshLayout(_ cells: [[TextDescriptor]]) -> ResolvedTableLayout {
        let measure: TextMeasure = { descriptor, width in
            let naturalWidth = CGFloat(descriptor.content.count) * 5
            let availableWidth = width.isFinite ? width : naturalWidth
            let visibleWidth = min(naturalWidth, availableWidth)
            let lineCount = max(1, Int(ceil(naturalWidth / max(1, availableWidth))))
            return CGSize(width: visibleWidth, height: CGFloat(lineCount) * 20)
        }
        let intrinsics = measureColumnIntrinsics(cells: cells, measure: measure, padding: .default)
        let solution = solveColumnWidths(intrinsics: intrinsics, availableWidth: 10_000)
        return layoutTableCells(
            cells: cells, columnWidths: solution.widths, alignments: [.left], measure: measure,
            padding: .default
        )
    }

    private func countingMeasure(_ counts: MeasureCounts) -> TextMeasure {
        { descriptor, width in
            counts.values[descriptor.content, default: 0] += 1
            let naturalWidth = CGFloat(descriptor.content.count) * 5
            let availableWidth = width.isFinite ? width : naturalWidth
            let visibleWidth = min(naturalWidth, availableWidth)
            let lineCount = max(1, Int(ceil(naturalWidth / max(1, availableWidth))))
            return CGSize(width: visibleWidth, height: CGFloat(lineCount) * 20)
        }
    }

    private func assertLayoutsEqual(
        _ actual: ResolvedTableLayout,
        _ expected: ResolvedTableLayout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.columnWidths, expected.columnWidths, file: file, line: line)
        XCTAssertEqual(actual.size, expected.size, file: file, line: line)
        XCTAssertEqual(actual.rows.count, expected.rows.count, file: file, line: line)
        for (actualRow, expectedRow) in zip(actual.rows, expected.rows) {
            XCTAssertEqual(actualRow.frame, expectedRow.frame, file: file, line: line)
            XCTAssertEqual(actualRow.isHeader, expectedRow.isHeader, file: file, line: line)
            XCTAssertEqual(actualRow.cells.count, expectedRow.cells.count, file: file, line: line)
            for (actualCell, expectedCell) in zip(actualRow.cells, expectedRow.cells) {
                XCTAssertEqual(actualCell.descriptor.content, expectedCell.descriptor.content, file: file, line: line)
                XCTAssertEqual(actualCell.frame, expectedCell.frame, file: file, line: line)
                XCTAssertEqual(actualCell.textFrame, expectedCell.textFrame, file: file, line: line)
            }
        }
    }

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

    private func snapshot(_ cells: [[TextDescriptor]], key: BlockKey) -> HotTableRenderSnapshot {
        HotTableRenderSnapshot(
            key: key,
            generation: 1,
            descriptor: MarkdownTableDescriptor(
                cells: cells, alignments: [.left], blockID: nil, lifecycle: .hot,
                layoutHash: 0, appearanceHash: 0
            ),
            width: 500,
            scale: 1,
            isFinal: false
        )
    }
}
#endif
