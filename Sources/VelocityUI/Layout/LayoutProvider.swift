// LayoutProvider.swift

import CoreGraphics

// MARK: - Protocol

/// Converts a flat list of measured (or estimated) layouts into absolute content-coordinate frames.
/// Implementations must be pure and nonisolated — called off-main during prefetch.
public protocol LayoutProvider: Sendable {
    nonisolated func frames(for layouts: [ResolvedLayout], availableWidth: CGFloat) -> [CGRect]
}

// MARK: - VerticalLayoutProvider

/// Stacks items top-to-bottom at full available width.
/// O(n). Called only on items-change and measure-completion — NEVER on the scroll path
/// or in layoutSubviews. See WorkingRange / partitioningIndex for the synchronous read path.
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
}

// MARK: - Frame refinement (vertical-specific)

extension VerticalLayoutProvider {
    /// Replace the frame at `index` with `newHeight`, shifting all subsequent origins by the delta.
    /// Returns the signed delta (positive = content grew). Caller adjusts contentOffset by this delta
    /// when the refined item sits above the visible viewport to avoid a visual jump.
    ///
    /// Vertical-specific: shifts a single column of origins. Masonry refinement requires per-column
    /// delta propagation and must not use this helper.
    /// O(n − index) — fires on measure completion, never on the 120 Hz scroll path.
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
    /// First index whose `frame.maxY > y`.
    /// Use with `viewportTop` (= `contentOffset.y`) to get the first partially-visible item.
    /// Frames must be sorted by minY ascending — guaranteed by VerticalLayoutProvider.
    public static func firstIndex(in frames: [CGRect], maxYGreaterThan y: CGFloat) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].maxY <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose `frame.minY >= y`.
    /// Use with `viewportBottom` (= `contentOffset.y + viewportHeight`) as the exclusive end of the
    /// visible range: every item in `[firstVisible, end)` satisfies `minY < viewportBottom`, meaning
    /// it is at least partially on screen (including items that straddle the bottom edge).
    /// Frames must be sorted by minY ascending — guaranteed by VerticalLayoutProvider.
    public static func firstIndex(in frames: [CGRect], minYNotLessThan y: CGFloat) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].minY < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Convenience: derives the visible index range in one call.
    /// Items in the returned range are partially or fully visible within `[viewportTop, viewportBottom)`.
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
