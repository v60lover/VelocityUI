// LayoutProvider.swift

import CoreGraphics

// MARK: - Protocol

/// Turns measured layouts into absolute frames, and answers what's visible and how tall the
/// content is. Must be pure and nonisolated — `visibleIndexRange`/`contentHeight` run on
/// `FeedScrollView`'s scroll path every frame, so no allocations or rebuilding `frames`.
public protocol LayoutProvider: Sendable {
    nonisolated func frames(for layouts: [ResolvedLayout], availableWidth: CGFloat) -> [CGRect]

    /// The contiguous range of indices visible within `[viewportTop, viewportBottom)`.
    /// `frames` must already be in index order, as produced by this provider's own `frames(for:)`.
    nonisolated func visibleIndexRange(
        in frames: [CGRect],
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int>

    /// Total height of the content.
    nonisolated func contentHeight(for frames: [CGRect]) -> CGFloat

    /// Width to measure each item's content at. Defaults to `availableWidth` verbatim — override only
    /// when the provider subdivides it into narrower columns, and keep in lockstep with `frames(for:)`.
    nonisolated func measureWidth(availableWidth: CGFloat) -> CGFloat
}

extension LayoutProvider {
    /// Default: measure at the full available width — unchanged behavior for providers (like
    /// `VerticalLayoutProvider`) that don't subdivide it into columns.
    public nonisolated func measureWidth(availableWidth: CGFloat) -> CGFloat {
        availableWidth
    }
}

// MARK: - VerticalLayoutProvider

/// Stacks items top-to-bottom at full available width. O(n); called only on items-change and
/// measure-completion — NEVER on the scroll path or in layoutSubviews.
public struct VerticalLayoutProvider: LayoutProvider, Sendable {
    public let spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public nonisolated func frames(for layouts: [ResolvedLayout], availableWidth: CGFloat) -> [CGRect] {
        var result = [CGRect]()
        result.reserveCapacity(layouts.count)
        var cursor: CGFloat = 0
        let lastIndex = layouts.count - 1
        for (i, layout) in layouts.enumerated() {
            let h = layout.totalFrame.height
            result.append(CGRect(x: 0, y: cursor, width: availableWidth, height: h))
            cursor += h
            if i < lastIndex { cursor += spacing }
        }
        return result
    }

    /// Same binary search as the static version below, just callable through `any LayoutProvider`.
    public nonisolated func visibleIndexRange(
        in frames: [CGRect],
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        Self.visibleIndexRange(in: frames, viewportTop: viewportTop, viewportBottom: viewportBottom)
    }

    /// The last item's bottom edge — items stack top to bottom, so that's the full height.
    public nonisolated func contentHeight(for frames: [CGRect]) -> CGFloat {
        frames.last.map(\.maxY) ?? 0
    }
}

// MARK: - Frame refinement (vertical-specific)

extension VerticalLayoutProvider {
    /// Replace the frame at `index` with `newHeight`, shifting all subsequent origins by the delta.
    /// Returns the signed delta (positive = content grew) — caller adjusts contentOffset by it when
    /// the refined item sits above the viewport, to avoid a visual jump. Vertical-specific; masonry
    /// needs per-column delta propagation instead.
    public static func refineFrames(_ frames: inout [CGRect], at index: Int, newHeight: CGFloat) -> CGFloat {
        guard index >= 0, index < frames.count else { return 0 }
        let delta = newHeight - frames[index].height
        guard delta != 0 else { return 0 }
        frames[index].size.height = newHeight
        for i in (index + 1)..<frames.count {
            frames[i].origin.y += delta
        }
        return delta
    }
}

// MARK: - Binary search (vertical-specific)

extension VerticalLayoutProvider {
    /// First index whose `frame.maxY > y` — use with `viewportTop` to get the first partially-visible
    /// item. Frames must be sorted by minY ascending.
    public static func firstIndex(in frames: [CGRect], maxYGreaterThan y: CGFloat) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].maxY <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose `frame.minY >= y` — use with `viewportBottom` as the exclusive end of the
    /// visible range. Frames must be sorted by minY ascending.
    public static func firstIndex(in frames: [CGRect], minYNotLessThan y: CGFloat) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].minY < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Convenience: derives the visible index range within `[viewportTop, viewportBottom)` in one call.
    public static func visibleIndexRange(
        in frames: [CGRect],
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        let first = firstIndex(in: frames, maxYGreaterThan: viewportTop)
        let end   = firstIndex(in: frames, minYNotLessThan: viewportBottom)
        return first..<end
    }
}
