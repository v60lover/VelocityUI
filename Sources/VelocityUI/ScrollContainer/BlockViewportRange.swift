import CoreGraphics

/// Finds the ordered block frames that intersect a cell-local viewport window.
/// Frames must be sorted by `minY` and must not overlap vertically.
public enum BlockViewportRange {
    /// Returns the active block range in O(log n + active blocks).
    public static func activeRange(in frames: [CGRect], window: CGRect) -> Range<Int> {
        guard !frames.isEmpty, !window.isNull, !window.isEmpty else { return 0..<0 }

        let first = firstIndex(in: frames, maxYGreaterThan: window.minY)
        let end = firstIndex(in: frames, minYNotLessThan: window.maxY)
        return first..<end
    }

    private static func firstIndex(in frames: [CGRect], maxYGreaterThan y: CGFloat) -> Int {
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let middle = (lower + upper) >> 1
            if frames[middle].maxY <= y { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private static func firstIndex(in frames: [CGRect], minYNotLessThan y: CGFloat) -> Int {
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let middle = (lower + upper) >> 1
            if frames[middle].minY < y { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
