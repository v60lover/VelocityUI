// WorkingRange.swift

import Foundation
import CoreGraphics

/// Combined layout + fragment snapshot for one cell slot.
/// Produced off-main during prefetch; read synchronously on the scroll path.
public struct CellEntry: Sendable {
    public let layout: ResolvedLayout
    public let fragments: [Fragment]
}

/// O(1) ring-buffer cache of CellEntry for items near the visible range.
///
/// Replaces the v4 [Int: ResolvedLayout] dictionary which hashed on every
/// lookup and rebuilt the entire dictionary on every eviction — both
/// unacceptable on the synchronous 120Hz scroll path.
///
/// Invariants:
/// - entry(at:) is O(1): one subtraction and one array index, no hashing.
/// - advance(to:) is O(shift): runs only in the pipeline, never during scroll.
/// - The read path (entry(at:)) never allocates.
@MainActor
public final class WorkingRange {
    private var buffer: [CellEntry?]
    private var rangeStart: Int = 0
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = [CellEntry?](repeating: nil, count: capacity)
    }

    /// O(1) — returns layout + fragments together. No allocation on read path.
    public func entry(at index: Int) -> CellEntry? {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return nil }
        return buffer[offset]
    }

    /// Convenience for tests and spike code that only need the layout.
    public func layout(at index: Int) -> ResolvedLayout? {
        entry(at: index)?.layout
    }

    /// Primary commit — called by RenderPipeline after measure + extractFragments.
    public func commit(_ layout: ResolvedLayout, _ fragments: [Fragment], at index: Int) {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return }
        buffer[offset] = CellEntry(layout: layout, fragments: fragments)
    }

    /// Spike-grade convenience — commits with an empty fragment list.
    /// Existing spike tests and fixture code use this.
    /// Production pipeline must use commit(_:_:at:).
    public func commit(_ layout: ResolvedLayout, at index: Int) {
        commit(layout, [], at: index)
    }

    /// Slide the window forward. O(shift) — runs in pipeline Task, not on scroll path.
    public func advance(to newStart: Int) {
        let shift = newStart - rangeStart
        guard shift > 0 else { return }
        if shift >= capacity {
            buffer = [CellEntry?](repeating: nil, count: capacity)
        } else {
            buffer.removeFirst(shift)
            buffer.append(contentsOf: [CellEntry?](repeating: nil, count: shift))
        }
        rangeStart = newStart
    }

    public func invalidateAll() {
        buffer = [CellEntry?](repeating: nil, count: capacity)
        rangeStart = 0
    }

    public var currentRangeStart: Int { rangeStart }
}
