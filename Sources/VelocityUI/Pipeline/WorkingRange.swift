// WorkingRange.swift

import Foundation
import CoreGraphics

/// O(1) ring-buffer cache of ResolvedLayouts for items near the visible range.
///
/// Replaces the v4 [Int: ResolvedLayout] dictionary which hashed on every
/// lookup and rebuilt the entire dictionary on every eviction — both
/// unacceptable on the synchronous 120Hz scroll path.
///
/// Invariants:
/// - layout(at:) is O(1): one subtraction and one array index, no hashing.
/// - advance(to:) is O(shift): runs only in the pipeline, never during scroll.
/// - The read path (layout(at:)) never allocates.
@MainActor
public final class WorkingRange {
    private var buffer: [ResolvedLayout?]
    private var rangeStart: Int = 0
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = [ResolvedLayout?](repeating: nil, count: capacity)
    }

    /// O(1) — no hash, no bounds check beyond simple subtraction.
    public func layout(at index: Int) -> ResolvedLayout? {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return nil }
        return buffer[offset]
    }

    /// O(1) write — pipeline side only, not called during scroll.
    public func commit(_ layout: ResolvedLayout, at index: Int) {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return }
        buffer[offset] = layout
    }

    /// Slide the window forward. O(shift) — runs in pipeline Task, not on scroll path.
    public func advance(to newStart: Int) {
        let shift = newStart - rangeStart
        guard shift > 0 else { return }
        if shift >= capacity {
            buffer = [ResolvedLayout?](repeating: nil, count: capacity)
        } else {
            buffer.removeFirst(shift)
            buffer.append(contentsOf: [ResolvedLayout?](repeating: nil, count: shift))
        }
        rangeStart = newStart
    }

    public func invalidateAll() {
        buffer = [ResolvedLayout?](repeating: nil, count: capacity)
        rangeStart = 0
    }

    public var currentRangeStart: Int { rangeStart }
}
