// GridLayoutProviderTests.swift

import XCTest
@testable import VelocityUI

final class GridLayoutProviderTests: XCTestCase {

    // MARK: - Deterministic randomness

    /// SplitMix64, seeded, so a failing randomized trial can be reproduced by re-running the
    /// test — unlike the system RNG, this always produces the same sequence for a given seed.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Helpers

    private func layout(height: CGFloat) -> ResolvedLayout {
        ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: height))
    }

    /// Ground-truth oracle: naive O(rows) scan. A row is visible iff [rowTop, rowBottom) overlaps
    /// [viewportTop, viewportBottom). Used to cross-validate GridLayoutProvider's binary-search
    /// implementation, independent of its own row-bounds machinery.
    private func naiveRowOverlapRange(
        frames: [CGRect],
        columns: Int,
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        guard !frames.isEmpty else { return 0..<0 }
        let rowCount = (frames.count + columns - 1) / columns
        var firstRow: Int?
        var lastRow: Int?
        for row in 0..<rowCount {
            let start = row * columns
            let end = min(start + columns, frames.count)
            let rowTop = frames[start].minY
            var rowBottom = frames[start].maxY
            for i in (start + 1)..<end { rowBottom = max(rowBottom, frames[i].maxY) }
            if rowBottom > viewportTop && rowTop < viewportBottom {
                if firstRow == nil { firstRow = row }
                lastRow = row
            }
        }
        guard let f = firstRow, let l = lastRow else { return 0..<0 }
        return (f * columns)..<min(frames.count, (l + 1) * columns)
    }

    // MARK: - frames(for:availableWidth:) — placement

    func testEmptyLayouts() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        XCTAssertTrue(provider.frames(for: [], availableWidth: 320).isEmpty)
    }

    func testColumnsClampedToAtLeastOne() {
        let provider = GridLayoutProvider(columns: 0, spacing: 8)
        XCTAssertEqual(provider.columns, 1)
        let negative = GridLayoutProvider(columns: -5, spacing: 8)
        XCTAssertEqual(negative.columns, 1)
    }

    func testUniformHeightPlacement_handComputed() {
        // 6 items, columns=3, height=100, spacing=8, availableWidth=320.
        // colWidth = (320 - 16) / 3 = 101.333...
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 6)
        let frames = provider.frames(for: layouts, availableWidth: 320)
        let colWidth: CGFloat = (320 - 8 * 2) / 3

        XCTAssertEqual(frames.count, 6)
        // Row 0: y = 0
        for i in 0..<3 {
            XCTAssertEqual(frames[i].origin.y, 0, accuracy: 0.001)
            XCTAssertEqual(frames[i].width, colWidth, accuracy: 0.001)
            XCTAssertEqual(frames[i].height, 100, accuracy: 0.001)
            XCTAssertEqual(frames[i].origin.x, CGFloat(i) * (colWidth + 8), accuracy: 0.001)
        }
        // Row 1: y = 100 + 8 = 108
        for i in 3..<6 {
            XCTAssertEqual(frames[i].origin.y, 108, accuracy: 0.001)
            XCTAssertEqual(frames[i].origin.x, CGFloat(i - 3) * (colWidth + 8), accuracy: 0.001)
        }
    }

    func testVariableHeightRowPlacement_rowHeightIsTallestItem() {
        // columns=3, spacing=8. Row 0 heights: 100, 50, 200 (max=200). Row 1 heights: 80, 60, 40.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [100, 50, 200, 80, 60, 40].map { layout(height: CGFloat($0)) }
        let frames = provider.frames(for: layouts, availableWidth: 320)

        // All of row 0 is top-aligned at y=0, heights verbatim.
        XCTAssertEqual(frames[0], CGRect(x: frames[0].minX, y: 0, width: frames[0].width, height: 100))
        XCTAssertEqual(frames[1].origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].height, 50, accuracy: 0.001)
        XCTAssertEqual(frames[2].origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(frames[2].height, 200, accuracy: 0.001)

        // Row 1 top advances by row 0's MAX height (200), not its last item's height.
        for i in 3..<6 {
            XCTAssertEqual(frames[i].origin.y, 208, accuracy: 0.001)
        }
        XCTAssertEqual(frames[3].height, 80, accuracy: 0.001)
        XCTAssertEqual(frames[4].height, 60, accuracy: 0.001)
        XCTAssertEqual(frames[5].height, 40, accuracy: 0.001)
    }

    // MARK: - measureWidth(availableWidth:)

    /// `measureWidth(availableWidth:)` must return the exact colWidth `frames(for:)` uses for
    /// positioning — both go through the same `colWidth(availableWidth:columns:spacing:)` helper,
    /// so this is really a same-source-of-truth check, not two independent formulas that happen
    /// to agree.
    func testMeasureWidth_equalsColWidthFramesActuallyUses() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 3)
        let frames = provider.frames(for: layouts, availableWidth: 320)

        let measureWidth = provider.measureWidth(availableWidth: 320)
        XCTAssertEqual(measureWidth, frames[0].width, accuracy: 0.001)
    }

    func testMeasureWidth_narrowerThanAvailableWidth_whenColumnsGreaterThan1() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let measureWidth = provider.measureWidth(availableWidth: 320)
        XCTAssertLessThan(measureWidth, 320, "a 3-column grid must measure at a narrower width than the container")
    }

    /// `columns: 1` degenerates to the full available width (minus zero inter-column spacing) —
    /// same identity `testColumns1_equalsVerticalLayoutProvider` proves for `frames(for:)`.
    func testMeasureWidth_columns1_equalsAvailableWidth() {
        let provider = GridLayoutProvider(columns: 1, spacing: 8)
        XCTAssertEqual(provider.measureWidth(availableWidth: 320), 320, accuracy: 0.001)
    }

    func testColWidthAndXMath() {
        let provider = GridLayoutProvider(columns: 4, spacing: 10)
        let layouts = [ResolvedLayout](repeating: layout(height: 50), count: 4)
        let frames = provider.frames(for: layouts, availableWidth: 390)
        let colWidth: CGFloat = (390 - 10 * 3) / 4

        XCTAssertTrue(frames.allSatisfy { abs($0.width - colWidth) < 0.001 })
        for (col, frame) in frames.enumerated() {
            XCTAssertEqual(frame.origin.x, CGFloat(col) * (colWidth + 10), accuracy: 0.001)
        }
    }

    func testRaggedFinalRow_countNotDivisibleByColumns() {
        // 7 items, columns=3 → rows of {3, 3, 1}.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 7)
        let frames = provider.frames(for: layouts, availableWidth: 320)

        XCTAssertEqual(frames.count, 7)
        // Item 6 is alone in row 2, at column 0.
        XCTAssertEqual(frames[6].origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(frames[6].origin.y, 216, accuracy: 0.001)  // 2 rows of 100 + 2 spacings of 8
    }

    func testColumns1_equalsVerticalLayoutProvider() {
        let layouts = [layout(height: 100), layout(height: 50), layout(height: 200), layout(height: 75)]
        let grid = GridLayoutProvider(columns: 1, spacing: 8)
        let vertical = VerticalLayoutProvider(spacing: 8)

        let gridFrames = grid.frames(for: layouts, availableWidth: 320)
        let verticalFrames = vertical.frames(for: layouts, availableWidth: 320)

        XCTAssertEqual(gridFrames, verticalFrames)
    }

    // MARK: - contentHeight

    func testContentHeight_uniformRows() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 6)
        let frames = provider.frames(for: layouts, availableWidth: 320)
        // Last row top = 108, max height = 100 → contentHeight = 208.
        XCTAssertEqual(GridLayoutProvider.contentHeight(for: frames, columns: 3), 208, accuracy: 0.001)
    }

    func testContentHeight_finalRowTallestItemNotLastIndex() {
        // columns=3. Row 0: heights 50,50,50 (max=50). Row 1: heights 40, 300, 20 — tallest
        // item (300) is the MIDDLE item of the final row, not the last index.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [50, 50, 50, 40, 300, 20].map { layout(height: CGFloat($0)) }
        let frames = provider.frames(for: layouts, availableWidth: 320)

        let lastRowTop: CGFloat = 58  // 50 + 8
        let expectedContentHeight = lastRowTop + 300
        XCTAssertEqual(GridLayoutProvider.contentHeight(for: frames, columns: 3), expectedContentHeight, accuracy: 0.001)
        // The last frame's own maxY (item 5: y=58, h=20 → 78) must NOT equal contentHeight.
        XCTAssertNotEqual(frames.last!.maxY, expectedContentHeight, accuracy: 0.001)
    }

    func testContentHeight_emptyFrames() {
        XCTAssertEqual(GridLayoutProvider.contentHeight(for: [], columns: 3), 0)
    }

    // MARK: - visibleIndexRange — against naive oracle

    func testVisibleIndexRange_emptyFrames() {
        let range = GridLayoutProvider.visibleIndexRange(in: [], columns: 3, viewportTop: 0, viewportBottom: 800)
        XCTAssertTrue(range.isEmpty)
    }

    func testVisibleIndexRange_viewportPastContent_isEmpty() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 9)
        let frames = provider.frames(for: layouts, availableWidth: 320)
        let range = GridLayoutProvider.visibleIndexRange(in: frames, columns: 3, viewportTop: 10_000, viewportBottom: 11_000)
        XCTAssertTrue(range.isEmpty)
    }

    func testVisibleIndexRange_partialTopRow() {
        // 9 items, columns=3, uniform height=100, spacing=8. Rows at y=0, 108, 216.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 9)
        let frames = provider.frames(for: layouts, availableWidth: 320)

        // Viewport starts mid-way through row 0 (y=50..200) → row 0 and row 1 visible, row 2
        // (top=216) is not, since 216 >= viewportBottom.
        let range = GridLayoutProvider.visibleIndexRange(in: frames, columns: 3, viewportTop: 50, viewportBottom: 200)
        let oracle = naiveRowOverlapRange(frames: frames, columns: 3, viewportTop: 50, viewportBottom: 200)
        XCTAssertEqual(range, oracle)
        XCTAssertEqual(range, 0..<6)
    }

    func testVisibleIndexRange_partialBottomRow() {
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 9)
        let frames = provider.frames(for: layouts, availableWidth: 320)

        // Viewport ends mid-way through row 1 (row1 y=[108,208)) → rows 0 and 1 visible, row 2 not.
        let range = GridLayoutProvider.visibleIndexRange(in: frames, columns: 3, viewportTop: 0, viewportBottom: 150)
        let oracle = naiveRowOverlapRange(frames: frames, columns: 3, viewportTop: 0, viewportBottom: 150)
        XCTAssertEqual(range, oracle)
        XCTAssertEqual(range, 0..<6)
    }

    func testVisibleIndexRange_raggedFinalRow() {
        // 7 items, columns=3 → rows {3,3,1}. Viewport covers only the final (ragged) row.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 7)
        let frames = provider.frames(for: layouts, availableWidth: 320)  // row2 top = 216

        let range = GridLayoutProvider.visibleIndexRange(in: frames, columns: 3, viewportTop: 220, viewportBottom: 400)
        let oracle = naiveRowOverlapRange(frames: frames, columns: 3, viewportTop: 220, viewportBottom: 400)
        XCTAssertEqual(range, oracle)
        // Row 2 only has 1 item (index 6); upperBound must clamp to frames.count, not 3*3=9.
        XCTAssertEqual(range, 6..<7)
    }

    func testVisibleIndexRange_columns1_equalsVerticalLayoutProvider() {
        let layouts = (0..<12).map { _ in layout(height: CGFloat.random(in: 40...200)) }
        let grid = GridLayoutProvider(columns: 1, spacing: 8)
        let gridFrames = grid.frames(for: layouts, availableWidth: 320)
        let verticalFrames = VerticalLayoutProvider(spacing: 8).frames(for: layouts, availableWidth: 320)

        let gridRange = GridLayoutProvider.visibleIndexRange(in: gridFrames, columns: 1, viewportTop: 108, viewportBottom: 408)
        let verticalRange = VerticalLayoutProvider.visibleIndexRange(in: verticalFrames, viewportTop: 108, viewportBottom: 408)
        XCTAssertEqual(gridRange, verticalRange)
    }

    func testVisibleIndexRange_randomizedAgainstOracle_variableHeights() {
        var rng = SeededGenerator(seed: 0xC0FFEE_1234_5678)
        for trial in 0..<200 {
            let columns = Int.random(in: 1...5, using: &rng)
            let count = Int.random(in: 0...40, using: &rng)
            let spacing = CGFloat.random(in: 0...16, using: &rng)
            let provider = GridLayoutProvider(columns: columns, spacing: spacing)
            let heights = (0..<count).map { _ in CGFloat.random(in: 10...250, using: &rng) }
            let layouts = heights.map { layout(height: $0) }
            let frames = provider.frames(for: layouts, availableWidth: 320)

            let contentHeight = GridLayoutProvider.contentHeight(for: frames, columns: columns)
            let viewportTop = CGFloat.random(in: -50...(contentHeight + 50), using: &rng)
            let viewportHeight = CGFloat.random(in: 20...400, using: &rng)
            let viewportBottom = viewportTop + viewportHeight

            let range = GridLayoutProvider.visibleIndexRange(in: frames, columns: columns, viewportTop: viewportTop, viewportBottom: viewportBottom)
            let oracle = naiveRowOverlapRange(frames: frames, columns: columns, viewportTop: viewportTop, viewportBottom: viewportBottom)
            XCTAssertEqual(range, oracle, "trial \(trial): columns=\(columns) count=\(count) spacing=\(spacing) viewport=[\(viewportTop),\(viewportBottom)) heights=\(heights)")
        }
    }

    // MARK: - Row-granularity justification

    /// Demonstrates the bead's key correctness point: under variable-height rows, a pure per-item
    /// frame-overlap set is NOT contiguous, which is why visibility must be computed at row
    /// granularity rather than by binary-searching individual item frames.
    func testPerItemOverlap_isNotContiguous_underVariableHeights() {
        // columns=3, spacing=8. Row 0 heights: 200, 50, 60 (top-aligned, share y=0).
        // Row 1 heights: 40, 40, 40 at y=208.
        let provider = GridLayoutProvider(columns: 3, spacing: 8)
        let layouts = [200, 50, 60, 40, 40, 40].map { layout(height: CGFloat($0)) }
        let frames = provider.frames(for: layouts, availableWidth: 320)

        let viewportTop: CGFloat = 190
        let viewportBottom: CGFloat = 210

        // Naive PER-ITEM overlap: item's own frame overlaps the viewport.
        let perItemOverlap = frames.indices.filter { i in
            frames[i].maxY > viewportTop && frames[i].minY < viewportBottom
        }

        // Item 0 (tall, [0,200)) and items 3,4,5 (row 1, [208,248)) overlap; items 1,2 (short,
        // [0,50) and [0,60)) do NOT — leaving a gap in the middle of the index set.
        XCTAssertEqual(perItemOverlap, [0, 3, 4, 5])
        XCTAssertFalse(perItemOverlap.contains(1))
        XCTAssertFalse(perItemOverlap.contains(2))
        // Prove non-contiguity directly: the set's span (max - min + 1) exceeds its count.
        let span = (perItemOverlap.max()! - perItemOverlap.min()! + 1)
        XCTAssertGreaterThan(span, perItemOverlap.count, "per-item overlap set has a gap — not contiguous")

        // The row-granular helper, by contrast, returns a contiguous range covering both rows
        // (row 0 bottom = 200 > 190, row 1 top = 208 < 210 → both rows visible).
        let rowRange = GridLayoutProvider.visibleIndexRange(in: frames, columns: 3, viewportTop: viewportTop, viewportBottom: viewportBottom)
        XCTAssertEqual(rowRange, 0..<6)
    }

    // MARK: - Performance

    /// Rough release-only smoke check (single-shot, no warmup, no p99) — not a benchmark.
    func testPerformance_10k_items_framesUnder1ms() {
        let provider = GridLayoutProvider(columns: 4, spacing: 8)
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 10_000)
        let start = CFAbsoluteTimeGetCurrent()
        _ = provider.frames(for: layouts, availableWidth: 390)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("GridLayoutProvider 10k items frames: \(String(format: "%.3f", ms)) ms")
        #if !DEBUG
        XCTAssertLessThan(ms, 1.0, "Frame pass for 10k items exceeded 1ms budget (\(String(format: "%.3f", ms)) ms)")
        #endif
    }
}
