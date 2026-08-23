// GridLayoutProvider.swift

import CoreGraphics

/// Places items row-major: item `i` sits at column `i % columns`, new row every `columns` items,
/// top-aligned to the tallest cell. Callers must measure each cell at `measureWidth(availableWidth:)`
/// before calling `frames(for:)` — this type takes `totalFrame.height` verbatim, no re-measurement.
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
        let colWidth = Self.colWidth(availableWidth: availableWidth, columns: columns, spacing: spacing)
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

    /// Cells must be measured at the same column width `frames(for:)` lays them out at — text
    /// re-wraps narrower, so height isn't `fullWidthHeight / columns`.
    public nonisolated func measureWidth(availableWidth: CGFloat) -> CGFloat {
        Self.colWidth(availableWidth: availableWidth, columns: columns, spacing: spacing)
    }

    /// Single source of truth for the column-width formula — shared by `frames(for:)` and
    /// `measureWidth(availableWidth:)` so positioning and measurement can never silently disagree.
    fileprivate static func colWidth(availableWidth: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }
}

// MARK: - contentHeight

extension GridLayoutProvider {
    /// Total content height: last row's top plus its max item height — NOT the last frame's `maxY`,
    /// since the tallest item in a ragged final row may not be the last index. `columns` must match
    /// the value used to build `frames`, or results silently break.
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
    /// Per-row `[minY, maxY)` bounds. Both arrays are monotonically non-decreasing across rows —
    /// that's what makes binary search over rows valid (per-item `maxY` within a row is NOT monotonic).
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
    /// `[viewportTop, viewportBottom)`; returns the smallest CONTIGUOUS range covering every visible
    /// row. Row-granular rather than item-granular because row tops/bottoms are monotonic (unlike
    /// per-item `maxY` within a variable-height row), which keeps the result contiguous. `columns`
    /// MUST match the value used to build `frames`, or results silently break.
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
