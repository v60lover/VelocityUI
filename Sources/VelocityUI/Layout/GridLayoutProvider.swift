// GridLayoutProvider.swift

import CoreGraphics

/// Places items row-major into a fixed number of columns: item `i` sits at column `i % columns`,
/// a new row starts every `columns` items, and each row is top-aligned with row height equal to
/// the tallest item in that row. Rows preserve spatial order == index order, so visibility stays
/// a single contiguous range — the same shape VerticalLayoutProvider relies on — even though item
/// heights within a row can vary.
///
/// CoreGraphics-only, pure arithmetic over `ResolvedLayout.totalFrame.height` — no re-measurement.
/// Callers that need heights reflecting wrapping at the narrower column width (e.g. text that
/// re-wraps once it no longer spans the full available width) must measure each cell at `colWidth`
/// BEFORE calling `frames(for:)` — this type takes `totalFrame.height` verbatim, exactly like
/// VerticalLayoutProvider.
///
/// Reached via `GridLayout.custom(GridLayoutProvider(columns:spacing:))` — there is no `.grid`
/// enum case; see `GridLayout`'s doc comment on preferring `.custom` over dead layout stubs.
public struct GridLayoutProvider: LayoutProvider, Sendable {
    public let columns: Int
    public let spacing: CGFloat

    /// - Parameter columns: clamped to >= 1.
    /// - Parameter spacing: clamped to >= 0.
    public init(columns: Int, spacing: CGFloat = 8) {
        self.columns = max(1, columns)
        self.spacing = max(0, spacing)
    }

    public nonisolated func frames(for layouts: [ResolvedLayout], availableWidth: CGFloat) -> [CGRect] {
        guard !layouts.isEmpty else { return [] }
        let colWidth = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var result = [CGRect]()
        result.reserveCapacity(layouts.count)
        var rowTop: CGFloat = 0
        var rowMaxHeight: CGFloat = 0
        for (i, layout) in layouts.enumerated() {
            let col = i % columns
            if i > 0 && col == 0 {
                rowTop += rowMaxHeight + spacing
                rowMaxHeight = 0
            }
            let h = layout.totalFrame.height
            let x = CGFloat(col) * (colWidth + spacing)
            result.append(CGRect(x: x, y: rowTop, width: colWidth, height: h))
            rowMaxHeight = max(rowMaxHeight, h)
        }
        return result
    }
}

// MARK: - contentHeight

extension GridLayoutProvider {
    /// Total content height: the last row's top plus the last row's max item height — NOT the
    /// last frame's `maxY`, since the tallest item in the final row may not be the last index
    /// (a ragged or variable-height final row can have its tallest item earlier in the row).
    ///
    /// `columns` MUST match the value used to build `frames` (via `frames(for:availableWidth:)`);
    /// a mismatch silently yields wrong results.
    public static func contentHeight(for frames: [CGRect], columns: Int) -> CGFloat {
        guard !frames.isEmpty else { return 0 }
        let columns = max(1, columns)
        let lastRowStart = ((frames.count - 1) / columns) * columns
        let rowTop = frames[lastRowStart].minY
        var rowMaxHeight: CGFloat = 0
        for i in lastRowStart..<frames.count {
            rowMaxHeight = max(rowMaxHeight, frames[i].height)
        }
        return rowTop + rowMaxHeight
    }
}

// MARK: - Row-granular visibility (grid-specific)

extension GridLayoutProvider {
    /// Per-row `[minY, maxY)` bounds, one entry per row. Both arrays are monotonically
    /// non-decreasing across rows (row tops only advance forward, rows never overlap because
    /// `spacing >= 0`) — that monotonicity is what makes binary search over rows valid, in
    /// contrast to per-item `frame.maxY` within a single variable-height row, which is NOT
    /// monotonic (items share `rowTop` — top-aligned — but have different heights/maxY).
    private static func rowBounds(for frames: [CGRect], columns: Int) -> (tops: [CGFloat], bottoms: [CGFloat]) {
        let rowCount = (frames.count + columns - 1) / columns
        var tops = [CGFloat](repeating: 0, count: rowCount)
        var bottoms = [CGFloat](repeating: 0, count: rowCount)
        for row in 0..<rowCount {
            let start = row * columns
            let end = min(start + columns, frames.count)
            tops[row] = frames[start].minY
            var bottom = frames[start].maxY
            var i = start + 1
            while i < end {
                bottom = max(bottom, frames[i].maxY)
                i += 1
            }
            bottoms[row] = bottom
        }
        return (tops, bottoms)
    }

    /// First row whose `bottoms[row] > y`. Mirrors `VerticalLayoutProvider.firstIndex(maxYGreaterThan:)`,
    /// applied to row bottoms instead of individual item `frame.maxY`.
    private static func firstRow(in bottoms: [CGFloat], bottomGreaterThan y: CGFloat) -> Int {
        var lo = 0, hi = bottoms.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if bottoms[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First row whose `tops[row] >= y`. Mirrors `VerticalLayoutProvider.firstIndex(minYNotLessThan:)`.
    private static func firstRow(in tops: [CGFloat], topNotLessThan y: CGFloat) -> Int {
        var lo = 0, hi = tops.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if tops[mid] < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Row-granular visible index range: a row is visible iff `[rowTop, rowBottom)` overlaps
    /// `[viewportTop, viewportBottom)`. Returns the smallest CONTIGUOUS index range covering every
    /// visible row: `[firstVisibleRow*columns, min(count, (lastVisibleRow+1)*columns))`.
    ///
    /// Deliberately row-granular, not item-granular: within a variable-height row, items are
    /// top-aligned (share `rowTop`) but have different `maxY`, so the per-item frame array is NOT
    /// sorted by `maxY` and applying `VerticalLayoutProvider`'s item-level binary search directly
    /// to grid frames is invalid. Binary-searching row tops/bottoms instead (both monotonic across
    /// rows) keeps the result contiguous — a pure per-item overlap set would NOT be contiguous
    /// under variable row heights (see
    /// `GridLayoutProviderTests.testPerItemOverlap_isNotContiguous_underVariableHeights`).
    /// Cost: each call rebuilds `rowBounds` from scratch, which is O(rows) time and allocates two
    /// O(rows) arrays (`tops`, `bottoms`); the binary searches themselves are O(log rows).
    ///
    /// Consequence of row granularity: a short item whose own frame sits above `viewportTop` but
    /// whose row is visible IS included — this over-mounts by at most `2*columns` items, trading a
    /// small amount of extra work for a contiguous range that reuses the vertical read-path.
    ///
    /// `columns` MUST match the value used to build `frames` (via `frames(for:availableWidth:)`);
    /// a mismatch silently yields wrong results.
    public static func visibleIndexRange(
        in frames: [CGRect],
        columns: Int,
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        guard !frames.isEmpty else { return 0..<0 }
        let columns = max(1, columns)
        let (tops, bottoms) = rowBounds(for: frames, columns: columns)
        let firstVisibleRow = firstRow(in: bottoms, bottomGreaterThan: viewportTop)
        let lastVisibleRowExclusive = firstRow(in: tops, topNotLessThan: viewportBottom)
        guard firstVisibleRow < lastVisibleRowExclusive else { return 0..<0 }
        let start = firstVisibleRow * columns
        let end = min(frames.count, lastVisibleRowExclusive * columns)
        return start..<end
    }
}
