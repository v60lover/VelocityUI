// FeedScrollView+Frames.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Frame management

    /// Rebuilds `resolvedFrames` in the current `tables` order. Heights come from
    /// `oldFrames[s.prevIdx]` for each survivor pair; other indices fall back to the synchronous
    /// `intrinsicHeight(for:width:)` estimate, and only to the flat `estimatedItemHeight`
    /// placeholder when intrinsic height can't be computed. Without the intrinsic fallback,
    /// every unmeasured image row would seed the flat estimate until the async pipeline
    /// commits — under sustained fast scroll `visRange` would churn every frame and the cell
    /// pool never converges. Populates `estimatedIndices` for any index not sourced from a known
    /// survivor height.
    ///
    /// Container width, honoring the first-layout fallback (`bounds.width` until
    /// `lastLayoutWidth` is set). Always the raw full width — route measure/cache-key calls
    /// through `measureWidth(for:)` instead.
    var containerWidth: CGFloat {
        lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
    }

    /// The width to measure a cell's content at, and to key `CacheKey`/`measureNode` calls with.
    /// For `VerticalLayoutProvider` this equals `containerWidth`; for `GridLayoutProvider` it's
    /// the narrower column width. Every measure/CacheKey call site must route through this so
    /// writers and readers never key-mismatch.
    func measureWidth(for containerWidth: CGFloat) -> CGFloat {
        layoutProvider.measureWidth(availableWidth: containerWidth)
    }

    /// Picks each item's height (needs `tables`/`oldFrames`/measurement), then hands positioning
    /// off to `layoutProvider.frames(for:availableWidth:)` — safe because every provider only
    /// reads `totalFrame.height` from its input.
    func rebuildFrames(oldFrames: [CGRect], survivors: [(prevIdx: Int, nextIdx: Int)]) {
        let w = containerWidth
        let measureW = measureWidth(for: w)
        var knownHeight = [CGFloat?](repeating: nil, count: tables.count)
        for s in survivors where s.prevIdx < oldFrames.count {
            knownHeight[s.nextIdx] = oldFrames[s.prevIdx].height
        }
        estimatedIndices.removeAll(keepingCapacity: true)
        var layouts = [ResolvedLayout]()
        layouts.reserveCapacity(tables.count)
        for i in tables.indices {
            let h: CGFloat
            if let known = knownHeight[i] {
                h = known
            } else if let intrinsic = intrinsicHeight(for: tables[i], width: measureW) {
                h = intrinsic
                estimatedIndices.insert(i)
            } else {
                h = estimatedItemHeight
                estimatedIndices.insert(i)
            }
            layouts.append(ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 0, height: h)))
        }
        resolvedFrames = layoutProvider.frames(for: layouts, availableWidth: w)
    }

    /// Refines heights for indices where WorkingRange has committed real layouts.
    /// Processes indices in ascending order — `refineFrames` shifts subsequent
    /// frames by the delta, so lowest-index-first is required for correct propagation.
    /// O(1) early-exit when `estimatedIndices` is empty (steady state).
    func refineKnownFrames() {
        guard !estimatedIndices.isEmpty || !_pendingFragmentIndices.isEmpty else { return }

        _refineIndexBuffer.removeAll(keepingCapacity: true)
        _refineIndexBuffer.append(contentsOf: estimatedIndices)
        for i in _pendingFragmentIndices where !estimatedIndices.contains(i) {
            _refineIndexBuffer.append(i)
        }
        _refineIndexBuffer.sort()
        var refined: [Int] = []
        var pendingRepositioned: Set<Int> = []

        for index in _refineIndexBuffer {
            guard index < resolvedFrames.count else {
                refined.append(index)
                continue
            }
            let entry: CellEntry
            if let wrEntry = workingRange.entry(at: index) {
                entry = wrEntry
            } else if _pendingFragmentIndices.contains(index), index < tables.count,
                      let cacheEntry = environment.layoutCache.cachedEntry(
                          for: CacheKey(layoutHash: tables[index].layoutHash, width: measureWidth(for: lastLayoutWidth))
                      ) {
                // WorkingRange hasn't been populated by the pipeline yet, but LayoutCache
                // already has the entry — materialize inline. Gated on _pendingFragmentIndices
                // (small, mount-bounded), not estimatedIndices, which spans the whole feed and
                // would probe LayoutCache per far-off, never-mounted index.
                workingRange.commit(cacheEntry.layout, cacheEntry.fragments, at: index)
                entry = cacheEntry
            } else {
                continue
            }
            let realHeight = entry.layout.totalFrame.height
            guard realHeight > 0 else { continue }

            let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: index, newHeight: realHeight)
            applyContentHeightDelta(delta)
            refined.append(index)

            // Deliver real fragments to cells that were mounted during a WorkingRange miss.
            // Check visibleCells first so the set is not mutated when no cell is present.
            if let cell = visibleCells[index], _pendingFragmentIndices.remove(index) != nil {
                cell.layer.frame = resolvedFrames[index]
                let ordinals = tables[index].leafOrdinals()
                let syncMap = buildSyncMap(for: entry.fragments, table: tables[index], ordinals: ordinals, index: index)
                let codeMap = buildCodeBodyContentMap(for: entry.fragments, table: tables[index], ordinals: ordinals)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: cell.layer.frame),
                    synchronousContent: syncMap, codeBodyContent: codeMap
                )
                spawnMediaFetches(for: cell, fragments: entering, itemID: tables[index].itemID,
                                  syncMap: syncMap)
                pendingRepositioned.insert(index)
            }
        }

        for i in refined { estimatedIndices.remove(i) }

        // Reposition visible cells whose scroll-space position shifted by refined height deltas.
        // Skip indices already repositioned above (frame was set before applyLayout read bounds.size).
        for (i, cell) in visibleCells {
            guard i < resolvedFrames.count else { continue }
            guard !pendingRepositioned.contains(i) else { continue }
            cell.layer.frame = resolvedFrames[i]
        }
    }

    /// True while the scroll sits in an edge rubber-band — over-pulled past the top (`< 0`) or
    /// bottom (`> maxOffset`) end. Mutating `contentSize.height` here moves the in-flight bounce
    /// animation's target, so UIScrollView re-solves and the viewport visibly jumps. Height
    /// writes are deferred until this is false again. False for all normal mid-content scrolling
    /// and inertia, so those paths are unchanged.
    private var isInBounceRegion: Bool {
        if let override = _testHooks.bounceRegionOverride { return override }
        let maxOffset = max(0, contentSize.height - bounds.height)
        return contentOffset.y < 0 || contentOffset.y > maxOffset
    }

    /// True only while over-pulled past the TOP (`contentOffset.y < 0`). This is the one edge where
    /// a streamed grow must defer its `contentSize.height` write: the top rubber-band settles toward
    /// a fixed target and a mid-bounce height write jumps the viewport. The BOTTOM over-pull is the
    /// opposite case (see `applyContentHeightDelta`) — there we WANT the height to grow into the
    /// over-scrolled gap so the pulled-open "void" fills with the streaming tail instead of
    /// rubber-banding back up.
    private var isInTopBounceRegion: Bool {
        if let override = _testHooks.topBounceRegionOverride { return override }
        return contentOffset.y < 0
    }

    /// Applies an incremental content-height change from a refined/grown frame. Writes immediately
    /// in the common case, and also on a BOTTOM over-pull — growing the height there fills the gap
    /// the user pulled open below the tail, so streaming text lands in that space rather than
    /// snapping back to a frozen edge. Only a TOP over-pull defers (accumulates) the delta, since a
    /// mid-bounce height write against the fixed top target jumps the viewport. The paint
    /// (resolvedFrames + cell layer) is done by the caller regardless — only this height write is
    /// gated.
    func applyContentHeightDelta(_ delta: CGFloat) {
        guard delta != 0 else { return }
        if isInTopBounceRegion {
            _deferredContentSizeDelta += delta
        } else if tailFollowMode != .off {
            // A tail-spacer floor can already sit above natural height — blindly adding `delta`
            // on top would over-count. Recompute directly instead; O(1) for VerticalLayoutProvider.
            contentSize.height = tailSpacerFloor(naturalHeight: layoutProvider.contentHeight(for: resolvedFrames))
        } else {
            contentSize.height += delta
        }
    }

    /// True when no gesture or bounce animation is in flight — nothing left to perturb, so a
    /// deferred height write is safe to commit even if `contentOffset` still sits at the edge.
    var isScrollAtRest: Bool {
        if let override = _testHooks.scrollAtRestOverride { return override }
        return !isTracking && !isDragging && !isDecelerating
    }

    /// Commits any height growth withheld during an edge bounce, in a single write. Fires once the
    /// scroll has left the bounce region OR the scroll has come to rest. The at-rest branch is
    /// essential: a rubber-band settle can land exactly at the frozen edge (`isInBounceRegion`
    /// still true by rounding) without ever producing an out-of-bounce layout pass. Without it the
    /// growth strands until the user manually scrolls — and at the bottom, with `contentSize`
    /// frozen, the only possible direction is up, which was the reported bug.
    func flushDeferredContentSizeIfNeeded() {
        guard _deferredContentSizeDelta != 0, !isInBounceRegion || isScrollAtRest else { return }
        if tailFollowMode != .off {
            contentSize.height = tailSpacerFloor(naturalHeight: layoutProvider.contentHeight(for: resolvedFrames))
        } else {
            contentSize.height += _deferredContentSizeDelta
        }
        _deferredContentSizeDelta = 0
    }

    func syncContentSize() {
        // In an edge bounce, defer: writing the authoritative height now perturbs the animation.
        // resolvedFrames stays truthful, so the post-settle flush lands the correct height.
        guard !isInBounceRegion else { return }
        let height = tailSpacerFloor(naturalHeight: layoutProvider.contentHeight(for: resolvedFrames))
        let target = CGSize(width: containerWidth, height: height)
        // Absolute write already carries the full truth from resolvedFrames — any accumulated
        // delta is now subsumed, so clear it to avoid a double-apply on the next flush.
        _deferredContentSizeDelta = 0
        if contentSize != target { contentSize = target }
    }

    // MARK: - Width change

    /// - Parameter isFirstLayout: `true` only for the very first width transition (the
    ///   `0 -> bounds.width` sentinel), where there's no prior width to invalidate against, so
    ///   the WR/LayoutCache invalidation is skipped. `rebuildFrames` + `syncContentSize` still
    ///   run unconditionally either way.
    func handleWidthChange(isFirstLayout: Bool) {
        if !isFirstLayout {
            workingRange.invalidateAll()
            _pendingPipelineInvalidation = true
            // LayoutCache eviction is async. Between now and completion, a boundary-crossing
            // notifyPipelineIfNeeded misses on the new-width key harmlessly — old-width CacheKeys
            // never collide with new-width ones, so no stale data pollutes the lookup.
            let cache = environment.layoutCache
            Task { await cache.invalidateAll() }
        }
        lastNotifiedLeadingIndex = -1
        rebuildFrames(oldFrames: [], survivors: [])
        syncContentSize()
    }
}
#endif
