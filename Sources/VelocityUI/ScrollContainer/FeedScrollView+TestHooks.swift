// FeedScrollView+TestHooks.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// Stored test-only observability/override state for `FeedScrollView`. A plain (non-generic)
/// class rather than an `extension FeedScrollView` member — extensions forbid stored instance
/// properties, but a fresh type declared in this file can hold them, and `FeedScrollView` then
/// holds exactly one reference to it (`_testHooks`).
///
/// Not `#if`-gated: `FeedScrollView`'s production code (counters, override reads) references
/// this type and its fields directly with no `#if canImport(XCTest)` guard, so the declaration
/// must always compile. The only XCTest-gated part of this test-hook pair is the `extension
/// FeedScrollView` below, which re-exposes these fields under their historical `_`-prefixed
/// test-facing names.
final class FeedScrollViewTestHooks {
    /// Counts Task spawns from leading-index boundary crossings inside `notifyPipelineIfNeeded`.
    /// Does NOT count the one-shot `onReachEnd` spawn — that fires at most once per page.
    var taskSpawnCount = 0

    /// Counts calls into the in-place block-diff's text measure/rasterize primitives. The
    /// anti-jank invariant under test: these counts per streaming update stay flat (bounded by
    /// the hot tail plus at most one just-finalized block) as a message's block count grows —
    /// never O(message length).
    var blockDiffMeasureCallCount = 0
    var blockDiffRasterizeCallCount = 0

    /// Counts calls into the hot-append path (`environment.hotBlockRasterizerStore.append`).
    /// The correct proxy for "the incremental rasterizer engaged" — the two counters above
    /// legitimately stop growing for the hot tail once this path is wired in.
    var blockDiffHotAppendCallCount = 0

    /// Counts successful `growHotBlock(_:)` calls — the side-channel engaged and painted the
    /// update without touching `items`/`differ`/`snapshot`.
    var growHotBlockSuccessCount = 0

    /// Branch counters for `AsyncFeed.itemsDiffer`'s buffer-identity fast path (O(1)) vs the
    /// `Equatable` deep-comparison fallback (O(n)). Incremented by `itemsDiffer` itself (a
    /// different type, hence not `private(set)` at the box level). Verifies the fast path is
    /// taken for CoW-preserved items arrays.
    var itemsDifferBufferHitCount = 0
    var itemsDifferDeepEqualCount = 0

    /// Overrides `isGestureActive` for tests, since UIKit's gesture-driven `isTracking`/
    /// `isDragging`/`isDecelerating` can't be set without a live touch. `nil` (default) falls
    /// back to the real UIKit signals.
    var gestureActiveOverride: Bool?

    /// Overrides `isInBounceRegion` for tests, since driving a real edge rubber-band needs a live
    /// pan gesture. `nil` (default) falls back to the real `contentOffset`/`contentSize` check.
    var bounceRegionOverride: Bool?

    /// Overrides `isInTopBounceRegion` for tests — the edge distinction that decides whether a
    /// streamed grow defers its `contentSize` write (top over-pull) or writes it immediately
    /// (bottom over-pull). `nil` (default) falls back to the real `contentOffset.y < 0` check.
    var topBounceRegionOverride: Bool?

    /// Overrides `isScrollAtRest` for tests — the real `isTracking`/`isDragging`/`isDecelerating`
    /// signals can't be set without a live touch. `nil` (default) falls back to them.
    var scrollAtRestOverride: Bool?

    /// Mirrors the `visRange` computed at the top of `updateVisibleCells()` — the range actually
    /// used to mount cells this layout pass. Test-only; no other production purpose.
    var lastVisibleRange: Range<Int> = 0..<0
}

#if canImport(XCTest)
extension FeedScrollView {
    var _taskSpawnCount: Int { _testHooks.taskSpawnCount }
    var _blockDiffMeasureCallCount: Int { _testHooks.blockDiffMeasureCallCount }
    var _blockDiffRasterizeCallCount: Int { _testHooks.blockDiffRasterizeCallCount }
    var _blockDiffHotAppendCallCount: Int { _testHooks.blockDiffHotAppendCallCount }
    var _growHotBlockSuccessCount: Int { _testHooks.growHotBlockSuccessCount }
    var _dequeueAllocCount: Int { cellPool.dequeueAllocCount }
    var _dequeueHitCount: Int { cellPool.dequeueHitCount }
    var _returnToPoolCount: Int { cellPool.returnToPoolCount }

    var _itemsDiffer_bufferHitCount: Int {
        get { _testHooks.itemsDifferBufferHitCount }
        set { _testHooks.itemsDifferBufferHitCount = newValue }
    }
    var _itemsDiffer_deepEqualCount: Int {
        get { _testHooks.itemsDifferDeepEqualCount }
        set { _testHooks.itemsDifferDeepEqualCount = newValue }
    }

    var _debugGestureActiveOverride: Bool? {
        get { _testHooks.gestureActiveOverride }
        set { _testHooks.gestureActiveOverride = newValue }
    }
    var _debugBounceRegionOverride: Bool? {
        get { _testHooks.bounceRegionOverride }
        set { _testHooks.bounceRegionOverride = newValue }
    }
    var _debugTopBounceRegionOverride: Bool? {
        get { _testHooks.topBounceRegionOverride }
        set { _testHooks.topBounceRegionOverride = newValue }
    }
    var _debugScrollAtRestOverride: Bool? {
        get { _testHooks.scrollAtRestOverride }
        set { _testHooks.scrollAtRestOverride = newValue }
    }

    /// Mirrors the `visRange` computed at the top of `updateVisibleCells()` — the range actually
    /// used to mount cells this layout pass. Test-only.
    var _lastVisibleRange: Range<Int> { _testHooks.lastVisibleRange }

    /// Mirrors `scrollDirection` as set in `layoutSubviews`. Test-only — lets tests assert the
    /// signal flips from a real `contentOffset.y` delta.
    var _lastScrollDirection: ScrollDirection { scrollDirection }

    /// Count of currently-mounted cells. Test-only observability for asserting the mounted set
    /// stays bounded to the working-range window rather than growing with total item count.
    var _visibleCellCount: Int { visibleCells.count }

    /// `WorkingRange.currentRangeStart` passthrough — `workingRange` itself is `internal`
    /// (module-only), unreachable from tests without this accessor.
    var _debugWorkingRangeStart: Int { workingRange.currentRangeStart }

    var _tableCacheCount: Int { tableCache.count }

    /// Returns nil-entry count in WorkingRange for indices in [start, end). Used by the
    /// integration suite to re-validate the ring-buffer warmup criterion end-to-end.
    func _workingRangeMissCount(from start: Int, to end: Int) -> Int {
        guard start < end else { return 0 }
        let clampedEnd = min(end, tables.count)
        guard start < clampedEnd else { return 0 }
        return (start..<clampedEnd).filter { workingRange.entry(at: $0) == nil }.count
    }

    /// Resolved frame for an index, in scroll-content coordinates. nil if never laid out. Lets
    /// tests compute a scroll offset from the real post-measure frame instead of a hardcoded
    /// estimate that would drift once WorkingRange refines real heights.
    func _debugResolvedFrame(at index: Int) -> CGRect? {
        index < resolvedFrames.count ? resolvedFrames[index] : nil
    }

    /// Exercises the internal `warmRange(viewportTop:viewportBottom:)` directly, against
    /// `resolvedFrames` as they stand after the test's own `layoutSubviews()` call.
    func _testWarmRange(viewportTop: CGFloat, viewportBottom: CGFloat) -> Range<Int> {
        warmRange(viewportTop: viewportTop, viewportBottom: viewportBottom)
    }

    /// Returns the root CALayer of the cell mounted at item index, or nil if not visible.
    /// Used by integration tests to compare layer identity across itemsDidChange calls.
    func _cellLayer(at index: Int) -> CALayer? {
        visibleCells[index]?.layer
    }

    /// True once the cell at `index` has revealed real image content for every image
    /// fragment — path-independent (covers both the mount-time synchronous fast path and
    /// the async `applyContent` path). `false` if the index has no mounted cell.
    /// See `RenderCell._debugIsContentRevealed`'s docstring for why tests must poll this
    /// instead of an applyContent-only delivery signal.
    func _debugIsContentRevealed(at index: Int) -> Bool {
        visibleCells[index]?._debugIsContentRevealed ?? false
    }

    /// See `RenderCell._debugPaintedBitmaps`'s doc. Empty dict if the index has no mounted cell.
    func _debugPaintedBitmaps(at index: Int) -> [Int: CGImage] {
        visibleCells[index]?._debugPaintedBitmaps ?? [:]
    }

    /// Re-derives fragments by walking `workingRange.entry(at: index)`'s `layout` through
    /// `extractFragments`, using the item's current `NodeTable`. `nil` if there's no committed
    /// WorkingRange entry or index is out of range. Test-only.
    func _debugExtractFragmentsFromWorkingRange(at index: Int) -> [Fragment]? {
        guard let entry = workingRange.entry(at: index), index < tables.count else { return nil }
        return extractFragments(table: tables[index], layout: entry.layout)
    }

    func _debugFragments(at index: Int) -> [Fragment] {
        workingRange.entry(at: index)?.fragments ?? []
    }

    /// Count of indices still awaiting fragment delivery via refineKnownFrames — cells mounted
    /// with `applyLayout([])` during a WorkingRange miss LayoutCache couldn't resolve inline.
    /// Should be 0 whenever LayoutCache is warm for all visible indices at mount time.
    var _pendingFragmentIndicesCount: Int { _pendingFragmentIndices.count }

    /// The pending, not-yet-committed content-height growth accumulated while in the bounce
    /// region. Non-zero only during an edge over-pull; returns to 0 once the deferred delta is
    /// flushed. Test-only observability for the defer/flush cycle.
    var _debugDeferredContentSizeDelta: CGFloat { _deferredContentSizeDelta }
}
#endif
#endif
