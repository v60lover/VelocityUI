// FeedScrollView+Scroll.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Synchronous scroll path

    /// Called from `layoutSubviews`. ZERO await on the scroll path itself.
    /// Media fetch Tasks are spawned at cell-mount time (a state change, not per frame).
    /// Returns the computed visible range so the caller can pass it to `checkReachEnd`.
    @discardableResult
    func updateVisibleCells() -> Range<Int> {
        guard !resolvedFrames.isEmpty else { return 0..<0 }

        let viewportTop    = contentOffset.y
        let viewportBottom = viewportTop + bounds.height

        let visRange = layoutProvider.visibleIndexRange(
            in: resolvedFrames,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom
        )
        _testHooks.lastVisibleRange = visRange

        // Keep-range for recycle decisions: same warm window that drives pipeline notification.
        let keepRange = warmRange(viewportTop: viewportTop, viewportBottom: viewportBottom)

        // FrozenBitmapStore is constructed (at RenderEnvironment composition-root time) before
        // this feed's real working-range shape is known — the driver is the only place that
        // shape ever becomes available. Size the budget from it here, once it grows, so the
        // store's LRU ceiling can never fall below the visible window's own bitmap footprint
        // (a budget that small would evict a still-visible block and force a re-freeze). Purely
        // a lock-guarded synchronous call — no `await`, safe on the scroll path.
        if keepRange.count > _frozenBudgetWindowCount {
            _frozenBudgetWindowCount = keepRange.count
            environment.frozenBitmapStore.sizeBudget(forWindowCount: keepRange.count)
        }

        // Collect out-of-range indices into the pre-allocated scratch buffer, then remove.
        // _recycleBuffer reuses its backing store after warm-up — no per-frame allocations.
        _recycleBuffer.removeAll(keepingCapacity: true)
        for index in visibleCells.keys where !keepRange.contains(index) {
            _recycleBuffer.append(index)
        }
        // Leaving blocks transfer to the evictable cache instead of being discarded. The resident
        // tier owns visible artifacts, so this avoids an LRU eviction/re-rasterize loop while a
        // token stream keeps updating neighboring blocks.
        if !_recycleBuffer.isEmpty {
            var leavingKeys: Set<BlockKey> = []
            for index in _recycleBuffer where index < tables.count && index < items.count {
                flatBlockKeys(for: tables[index], itemID: items[index].id, into: &leavingKeys)
            }
            if !leavingKeys.isEmpty {
                environment.visibleBlockStore.demote(leavingKeys, to: environment.frozenBitmapStore)
                // Generic hot text owns an NSTextLayoutManager and can be discarded here. A code
                // stream retains its split sealed/tail delivery until it seals or its item leaves,
                // so a viewport re-entry cannot reconstruct a stretched single-layer bitmap.
                environment.hotBlockRasterizerStore.evict(leavingKeys)
            }
        }
        for index in _recycleBuffer {
            _pendingFragmentIndices.remove(index)
            if let cell = visibleCells.removeValue(forKey: index) {
                cell.layer.removeFromSuperlayer()
                returnToPool(cell)
            }
        }

        // Set when a LayoutCache-hit mount below refines resolvedFrames for an index whose real
        // height differs from the placeholder — signals already-mounted cells at later indices
        // may need repositioning below.
        var didRefineDuringMount = false

        // Keys of newly mounted cells are promoted after this pass. Existing cache entries move
        // into the resident tier; a cache miss remains a normal pipeline/first-render path.
        var enteringKeys: Set<BlockKey> = []

        // Mount newly visible cells.
        for index in visRange {
            guard index < resolvedFrames.count, index < tables.count else { continue }
            if let keptCell = visibleCells[index] {
                // A cell kept in-place by itemsDidChange's reuseDecision branch is detached
                // (superlayer == nil) but still bound — reattach here in ascending visRange
                // order so z-order matches display order. Steady-state already-attached cells
                // are a single pointer read and `continue`.
                if keptCell.layer.superlayer == nil {
                    keptCell.layer.frame = resolvedFrames[index]
                    layer.addSublayer(keptCell.layer)
                }
                if let entry = workingRange.entry(at: index) {
                    let ordinals = tables[index].leafOrdinals()
                    let syncMap = buildSyncMap(for: entry.fragments, table: tables[index], ordinals: ordinals, index: index)
                    // A code body scrolling into view inside an already-mounted (tall, streaming)
                    // cell enters here, not the fresh-mount branch below -- so it needs the same
                    // codeBodyContent map. Without it the body mounts with an empty chunk list and
                    // paints nothing (background + header still show), the "scroll to a sealed code
                    // block, see only the card and its header" bug.
                    let codeMap = buildCodeBodyContentMap(for: entry.fragments, table: tables[index], ordinals: ordinals)
                    let entering = keptCell.updateBlockViewport(
                        viewportInCell: blockViewport(for: keptCell.layer.frame),
                        synchronousContent: syncMap, codeBodyContent: codeMap
                    )
                    reportMissingRasterLayers(in: keptCell, fragments: entry.fragments, table: tables[index], ordinals: ordinals)
                    spawnMediaFetches(for: keptCell, fragments: entering, itemID: tables[index].itemID, syncMap: syncMap)
                }
                continue
            }

            let frame = resolvedFrames[index]
            let table = tables[index]
            let cell  = dequeue(kind: .standard)

            if index < items.count {
                flatBlockKeys(for: table, itemID: items[index].id, into: &enteringKeys)
            }

            cell.prepareForReuse(for: table.itemID)

            if let entry = workingRange.entry(at: index) {
                cell.layer.frame = frame
                let ordinals = table.leafOrdinals()
                let syncMap = buildSyncMap(for: entry.fragments, table: table, ordinals: ordinals, index: index)
                let codeMap = buildCodeBodyContentMap(for: entry.fragments, table: table, ordinals: ordinals)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: frame),
                    synchronousContent: syncMap, codeBodyContent: codeMap
                )
                reportMissingRasterLayers(in: cell, fragments: entry.fragments, table: table, ordinals: ordinals)
                spawnMediaFetches(for: cell, fragments: entering, itemID: table.itemID,
                                  syncMap: syncMap)
            } else if let entry = environment.layoutCache.cachedEntry(
                for: CacheKey(layoutHash: table.layoutHash, width: measureWidth(for: lastLayoutWidth))
            ) {
                // WorkingRange miss, but LayoutCache already has the entry (prior pipeline pass,
                // or AsyncFeed.warmUp()). Materialize inline so this cell gets real fragments
                // this pass instead of a placeholder frame.
                workingRange.commit(entry.layout, entry.fragments, at: index)

                // resolvedFrames[index] may still hold the placeholder — refineKnownFrames ran
                // before WorkingRange had anything to refine from. Refine here inline so the
                // cell mounts at its real height instead of the stale estimate.
                let realHeight = entry.layout.totalFrame.height
                var mountFrame = frame
                if realHeight > 0 {
                    let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: index, newHeight: realHeight)
                    if delta != 0 {
                        applyContentHeightDelta(delta)
                        didRefineDuringMount = true
                    }
                    mountFrame = resolvedFrames[index]
                    estimatedIndices.remove(index)
                }

                cell.layer.frame = mountFrame
                let ordinals = table.leafOrdinals()
                let syncMap = buildSyncMap(for: entry.fragments, table: table, ordinals: ordinals, index: index)
                let codeMap = buildCodeBodyContentMap(for: entry.fragments, table: table, ordinals: ordinals)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: mountFrame),
                    synchronousContent: syncMap, codeBodyContent: codeMap
                )
                reportMissingRasterLayers(in: cell, fragments: entry.fragments, table: table, ordinals: ordinals)
                spawnMediaFetches(for: cell, fragments: entering, itemID: table.itemID,
                                  syncMap: syncMap)
            } else {
                // WorkingRange miss: placeholder gradient at estimated frame.
                // Real fragments arrive via refineKnownFrames once the pipeline commits.
                cell.layer.frame = frame
                cell.applyLayout([])
                _pendingFragmentIndices.insert(index)
            }

            layer.addSublayer(cell.layer)
            visibleCells[index] = cell
        }

        if !enteringKeys.isEmpty {
            environment.visibleBlockStore.promote(enteringKeys, from: environment.frozenBitmapStore)
        }

        // A LayoutCache-hit refine above shifts resolvedFrames for indices after the refined
        // one — any cell already mounted at a higher index needs its layer.frame re-synced.
        if didRefineDuringMount {
            for (i, cell) in visibleCells {
                guard i < resolvedFrames.count else { continue }
                cell.layer.frame = resolvedFrames[i]
            }
        }

        syncContentSize()
        return visRange
    }

    /// The index range to keep warm (measured, mounted, prefetched) around the visible viewport —
    /// drives both `updateVisibleCells`'s recycle bounds and the pipeline measure window, so
    /// mounting never asks for an index the pipeline was never told to warm.
    ///
    /// Runs on the scroll path: allocation-free, O(log n) — one extra binary search over the
    /// already-built `resolvedFrames`. No rebuild, no Task, no await.
    func warmRange(viewportTop: CGFloat, viewportBottom: CGFloat) -> Range<Int> {
        switch warmWindow {
        case .items(let ahead, let behind):
            let vis = layoutProvider.visibleIndexRange(
                in: resolvedFrames, viewportTop: viewportTop, viewportBottom: viewportBottom)
            return max(0, vis.lowerBound - behind) ..< min(resolvedFrames.count, vis.upperBound + ahead)
        case .screens(let leading, let trailing):
            let H = bounds.height
            return layoutProvider.visibleIndexRange(
                in: resolvedFrames,
                viewportTop:    viewportTop    - trailing * H,
                viewportBottom: viewportBottom + leading  * H)
        }
    }

    /// One viewport above and below the visible bounds keeps nearby blocks warm without making
    /// a tall cell retain its entire layer tree.
    func blockViewport(for cellFrame: CGRect) -> CGRect {
        let prefetch = bounds.height
        return CGRect(
            x: 0,
            y: contentOffset.y - cellFrame.minY - prefetch,
            width: cellFrame.width,
            height: bounds.height + (2 * prefetch)
        )
    }

    // MARK: - Pipeline notification

    func notifyPipelineIfNeeded() {
        guard !tables.isEmpty, !resolvedFrames.isEmpty else { return }

        let visTop    = contentOffset.y
        let visBottom = visTop + bounds.height
        let visRange  = layoutProvider.visibleIndexRange(
            in: resolvedFrames, viewportTop: visTop, viewportBottom: visBottom)
        let leading   = visRange.lowerBound

        guard leading != lastNotifiedLeadingIndex else { return }
        lastNotifiedLeadingIndex = leading

        // The window sent to the pipeline is geometrically wider than `visRange` in screens
        // mode: the trigger (`leading` changing) stays item-based, but the width measured now
        // tracks the real viewport.
        let capturedWarmRange = warmRange(viewportTop: visTop, viewportBottom: visBottom)
        let capturedTables = tables
        // The measure width, not the raw container width, so RenderPipeline's CacheKey calls
        // key on the same width every read site uses.
        let capturedWidth  = measureWidth(for: bounds.width)
        let capturedScale  = max(1, traitCollection.displayScale)  // same guard as spawnMediaFetches
        let capturedDirection = scrollDirection

        // Consumed synchronously, before the Task's await gap — a new invalidation that lands
        // while this Task is in flight sets the flag again and rides the NEXT
        // notifyPipelineIfNeeded call instead of being lost or double-consumed here.
        let shouldInvalidate = _pendingPipelineInvalidation
        _pendingPipelineInvalidation = false

        _testHooks.taskSpawnCount += 1
        environment.pipelineTaskSpawnObserver?()

        Task { [weak self] in
            guard let self else { return }
            await self.pipeline.onIndexBoundary(
                warmRange: capturedWarmRange,
                leadingIndex: leading,
                workingRange: self.workingRange,
                tables: capturedTables,
                availableWidth: capturedWidth,
                scale: capturedScale,
                direction: capturedDirection,
                invalidate: shouldInvalidate
            )
            await self.pipeline.waitForCurrentPrefetch()
            self.setNeedsLayout()
        }
    }

    // MARK: - Raster repair

    /// Schedules an async repair for any indices `buildSyncMap` flagged this pass — see
    /// VelocityUI-8otc.6.3. No-op while a repair is already in flight, so repeated layout passes
    /// during one repair coalesce into a single raster job per index. Called from
    /// `layoutSubviews`, after `updateVisibleCells`/`notifyPipelineIfNeeded` — itself
    /// `await`-free, so it doesn't touch the zero-await scroll-path contract.
    func requestRasterRepairIfNeeded() {
        guard _repairTask == nil, !_pendingRasterRepairIndices.isEmpty else { return }

        let indices = _pendingRasterRepairIndices
        let capturedTables = tables
        let capturedWidth = measureWidth(for: bounds.width)
        let capturedScale = max(1, traitCollection.displayScale)
        let pipeline = self.pipeline
        let workingRange = self.workingRange
        let observer = environment.rasterDiagnosticsObserver
        let candidateKeys: [BlockKey]?
        if let observer {
            let keys = rasterDiagnosticCandidateKeys(for: indices, tables: capturedTables)
            observer.emit(.repairStarted(indices: indices.sorted(), candidateKeys: keys))
            candidateKeys = keys
        } else {
            candidateKeys = nil
        }

        _testHooks.repairTaskSpawnCount += 1
        _repairTask = Task { [weak self] in
            await pipeline.repairArtifacts(
                indices: indices,
                workingRange: workingRange,
                tables: capturedTables,
                availableWidth: capturedWidth,
                scale: capturedScale
            )
            guard let self else { return }
            if let observer, let candidateKeys {
                let storedKeys = candidateKeys.filter { self.environment.frozenBitmapStore.bitmap(for: $0) != nil }
                let storedSet = Set(storedKeys)
                observer.emit(.repairFinished(
                    indices: indices.sorted(),
                    candidateKeys: candidateKeys,
                    storedKeys: storedKeys,
                    missingKeys: candidateKeys.filter { !storedSet.contains($0) }
                ))
            }
            // Repaint: the repaired bitmaps now live in FrozenBitmapStore. The next
            // updateVisibleCells pass re-runs buildSyncMap for every still-mounted cell, which
            // promotes and paints them — no separate delivery channel needed.
            self._pendingRasterRepairIndices.subtract(indices)
            self._repairTask = nil
            self.setNeedsLayout()
        }
    }

    private func rasterDiagnosticCandidateKeys(for indices: Set<Int>, tables: [NodeTable]) -> [BlockKey] {
        indices.sorted().flatMap { index -> [BlockKey] in
            guard index < tables.count, let entry = workingRange.entry(at: index) else { return [] }
            let table = tables[index]
            let ordinals = table.leafOrdinals()
            return entry.fragments.compactMap { fragment in
                switch fragment.content {
                case .text(let descriptor):
                    guard case .none = descriptor.codeBlockRole else { return nil }
                case .table, .mathBlock:
                    break
                default:
                    return nil
                }
                return canonicalBlockKey(
                    boxedItemID: table.itemID,
                    fragment: fragment,
                    logicalOrdinal: ordinals[fragment.id] ?? fragment.id
                )
            }
        }
    }

    // MARK: - Reach-end detection

    /// Called from `layoutSubviews` after `updateVisibleCells` — NOT from inside
    /// updateVisibleCells itself, so the sync scroll path remains Task-free.
    func checkReachEnd(visRange: Range<Int>) {
        guard !reachEndFired, let handler = onReachEnd else { return }
        let trailingThreshold = max(0, items.count - max(1, reachEndThreshold))
        guard visRange.upperBound >= trailingThreshold else { return }
        reachEndFired = true
        Task { await handler() }
    }
}
#endif
