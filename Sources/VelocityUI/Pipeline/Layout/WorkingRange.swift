// WorkingRange.swift

import Foundation
import CoreGraphics

/// Combined layout + fragment snapshot for one cell slot.
/// Produced off-main during prefetch; read synchronously on the scroll path.
public struct CellEntry: Sendable {
    public let layout: ResolvedLayout
    public let fragments: [Fragment]
    /// Rasterized text/table/math bitmaps captured at the same time as the layout. A
    /// `LayoutCache` hit whose `rasterIdentity` still matches the live theme+scale re-keys these
    /// to the requesting item (cheap — see `RenderPipeline`'s hit branch) instead of re-running
    /// `rasterizeTextArtifacts`/`rasterizeTableArtifacts`/`rasterizeMathArtifacts` — those calls
    /// are a full re-raster every time, not a cache-backed lookup, so re-running them on every
    /// hit is what starved the pipeline during streaming (VelocityUI-4uyk).
    let artifacts: [TextBitmapArtifact]
    /// Theme generation + display scale in effect when `artifacts` was rasterized, mirroring
    /// `CodeBodyRasterIdentity`. A hit under a different (later) identity means the pixels are
    /// stale — the reader must re-rasterize rather than reuse, even though the layout/fragments
    /// are still valid (geometry doesn't depend on theme or scale).
    let rasterIdentity: CodeBodyRasterIdentity

    init(
        layout: ResolvedLayout, fragments: [Fragment], artifacts: [TextBitmapArtifact] = [],
        rasterIdentity: CodeBodyRasterIdentity = CodeBodyRasterIdentity(themeGeneration: 0, scale: 0)
    ) {
        self.layout = layout
        self.fragments = fragments
        self.artifacts = artifacts
        self.rasterIdentity = rasterIdentity
    }
}

/// O(1) ring-buffer cache of CellEntry for items near the visible range — no hashing or
/// per-lookup allocation, required for the synchronous 120Hz scroll path.
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
    /// Idempotent: a plain array-index write, so racing callers writing identical data for the
    /// same index just overwrite the same slot.
    public func commit(_ layout: ResolvedLayout, _ fragments: [Fragment], at index: Int) {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return }
        buffer[offset] = CellEntry(layout: layout, fragments: fragments)
    }

    /// Test/fixture convenience — commits with an empty fragment list. Production code should
    /// use `commit(_:_:at:)`.
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

    /// Resets the ring buffer to start at `newStart`, clearing all entries.
    /// Use when the visible range moves backward past the current window start.
    /// O(capacity) — acceptable on a direction change; not called on the scroll path.
    public func resetRange(to newStart: Int) {
        precondition(newStart < rangeStart || rangeStart == 0,
            "resetRange(to:) is for backward scroll; use advance(to:) to move forward")
        buffer = [CellEntry?](repeating: nil, count: capacity)
        rangeStart = newStart
    }

    public func invalidateAll() {
        buffer = [CellEntry?](repeating: nil, count: capacity)
        rangeStart = 0
    }

    /// Drops one stale item while preserving other resolved slots in the window.
    public func invalidate(at index: Int) {
        let offset = index - rangeStart
        guard offset >= 0, offset < capacity else { return }
        buffer[offset] = nil
    }

    public var currentRangeStart: Int { rangeStart }
}
