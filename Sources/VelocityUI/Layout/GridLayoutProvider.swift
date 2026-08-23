// GridLayoutProvider.swift

import CoreGraphics

/// Places items row-major: item `i` sits at column `i % columns`, a new row starts every
/// `columns` items, each row top-aligned to its tallest item. Spatial order == index order,
/// so visibility stays one contiguous range — same shape `VerticalLayoutProvider` relies on.
///
/// Pure arithmetic over `ResolvedLayout.totalFrame.height` — no re-measurement. Callers needing
/// heights that reflect wrapping at the narrower column width must measure each cell at
/// `colWidth` BEFORE calling `frames(for:)`; this type takes `totalFrame.height` verbatim.
///
/// Reached via `GridLayout.custom(GridLayoutProvider(columns:spacing:))` — there is no `.grid`
/// case; see `GridLayout`'s doc comment on preferring `.custom` over dead layout stubs.
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

    /// Same row-granular search as the static version below, using `self.columns`.
    public nonisolated func visibleIndexRange(
        in frames: [CGRect],
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        Self.visibleIndexRange(in: frames, columns: columns, viewportTop: viewportTop, viewportBottom: viewportBottom)
    }

    /// Same as the static `contentHeight(for:columns:)` below, using `self.columns`.
    public nonisolated func contentHeight(for frames: [CGRect]) -> CGFloat {
        Self.contentHeight(for: frames, columns: columns)
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
    /// `[viewportTop, viewportBottom)`. Returns the smallest CONTIGUOUS range covering every visible
    /// row: `[firstVisibleRow*columns, min(count, (lastVisibleRow+1)*columns))`.
    ///
    /// Row-granular, not item-granular, on purpose: within a variable-height row items are
    /// top-aligned but have different `maxY`, so per-item frames aren't sorted by `maxY` and
    /// `VerticalLayoutProvider`'s item-level binary search doesn't apply directly. Row tops/bottoms
    /// ARE monotonic across rows, so binary-searching those keeps the result contiguous — a raw
    /// per-item overlap set would not be, under variable row heights (see
    /// `testPerItemOverlap_isNotContiguous_underVariableHeights`). Rebuilds `rowBounds` from scratch
    /// each call: O(rows) time/allocation, O(log rows) for the binary searches themselves.
    ///
    /// Trade-off: a short item above `viewportTop` whose row is visible IS included — over-mounts
    /// by at most `2*columns` items in exchange for a contiguous range on the vertical read-path.
    ///
    /// `columns` MUST match the value used to build `frames`; a mismatch silently yields wrong results.
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
