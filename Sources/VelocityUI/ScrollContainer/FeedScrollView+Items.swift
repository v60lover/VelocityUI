// FeedScrollView+Items.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Items change

    func itemsDidChange(from oldItems: [Item]) {
        // Cleared unconditionally regardless of call site — any call fully resyncs
        // snapshot/tables to the current items, so a pending marker is always stale afterward.
        _pendingItemsDiffBase = nil
        guard let builder = cellBuilder else { return }

        let nextTables = buildNextTables(using: builder)
        let nextSnapshot = LayoutSnapshot(tables: nextTables)
        let changeSet = differ.diff(prev: snapshot, next: nextSnapshot)

        guard changeSet.hasChanges else {
            snapshot = nextSnapshot
            tables = nextTables
            return
        }

        let (oldFrames, survivors) = computeSurvivorsAndRecycleRemoved(changeSet: changeSet)
        let plan = decideInvalidation(changeSet: changeSet, survivors: survivors)

        commitSnapshot(nextSnapshot, nextTables: nextTables, oldFrames: oldFrames, survivors: survivors)

        let tookInPlaceFastPath = reconcileVisibleCells(changeSet: changeSet, plan: plan)

        finishItemsChange(itemCountGrew: items.count > oldItems.count, tookInPlaceFastPath: tookInPlaceFastPath)
    }

    /// Builds `nextTables` from `items`, reusing a cached table when `itemSignature` reports an
    /// unchanged signature and evicting cache entries for items no longer present.
    private func buildNextTables(using builder: @MainActor (Item) -> any RenderNode) -> [NodeTable] {
        var nextTables: [NodeTable] = []
        nextTables.reserveCapacity(items.count)
        if let signature = itemSignature {
            for item in items {
                let sig = signature(item)
                if let hit = tableCache[item.id], hit.sig == sig {
                    nextTables.append(hit.table)
                } else {
                    let table = flatten(builder(item), itemID: item.id, contentSizeCategory: contentSizeCategory)
                    nextTables.append(table)
                    tableCache[item.id] = (sig, table)
                }
            }
            if tableCache.count > items.count {
                let activeIDs = Set(items.lazy.map(\.id))
                let toRemove = tableCache.keys.filter { !activeIDs.contains($0) }
                for key in toRemove { tableCache.removeValue(forKey: key) }
            }
        } else {
            for item in items {
                nextTables.append(flatten(builder(item), itemID: item.id, contentSizeCategory: contentSizeCategory))
            }
        }
        return nextTables
    }

    /// Captures old frames and builds (prevIdx, nextIdx) survivors before clobbering them —
    /// covers all items with a known previous height, Int-keyed so there's zero AnyHashable
    /// boxing — then recycles cells for removed items (prevIdx is the old index in
    /// `visibleCells`). Must run before `tables`/`snapshot` are overwritten with the next
    /// generation.
    private func computeSurvivorsAndRecycleRemoved(
        changeSet: ChangeSet
    ) -> (oldFrames: [CGRect], survivors: [(prevIdx: Int, nextIdx: Int)]) {
        let oldFrames = resolvedFrames
        var survivors: [(prevIdx: Int, nextIdx: Int)] = []
        survivors.reserveCapacity(tables.count)
        for e in changeSet.survived      { survivors.append(e) }
        for e in changeSet.layoutChanged { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }
        for e in changeSet.appearanceChanged { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }
        for e in changeSet.mediaChanged  { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }

        for r in changeSet.removed {
            if let cell = visibleCells.removeValue(forKey: r.prevIdx) {
                returnToPool(cell)
            }
        }
        return (oldFrames, survivors)
    }

    /// Small value-type carrier passed from `decideInvalidation` to `reconcileVisibleCells` —
    /// replaces the long-lived shared locals the pre-decomposition `itemsDidChange` glued its
    /// phases together with.
    private struct DiffPlan {
        let survivors: [(prevIdx: Int, nextIdx: Int)]
        let needsFullInvalidation: Bool
        let canDeferInvalidation: Bool
        let blockDiffInputs: [Int: (previousTable: NodeTable, newTable: NodeTable, previousFragments: [Fragment])]
    }

    /// Decides whether this change needs a full `WorkingRange` invalidation, and whether that
    /// invalidation can be deferred pending an in-place block diff.
    private func decideInvalidation(
        changeSet: ChangeSet, survivors: [(prevIdx: Int, nextIdx: Int)]
    ) -> DiffPlan {
        // Invalidate WorkingRange when any layout-impacting change exists.
        let needsFullInvalidation = !changeSet.layoutChanged.isEmpty ||
                                    !changeSet.removed.isEmpty ||
                                    !changeSet.added.isEmpty

        // VelocityUI-socg C4: a pure streaming update (every layoutChanged entry is a same-position,
        // currently-visible survivor — no add/remove) is a candidate to SKIP full-window invalidation
        // and patch WorkingRange directly for the block-diff-resolved indices instead (post-loop
        // commit below). This only checks eligibility — the fast path is taken only if every
        // layoutChanged entry's block diff actually succeeds, decided after the loop. Off-screen
        // layoutChanged entries are excluded here because applyInPlaceBlockDiff only runs for visible
        // cells below — an off-screen entry would never get patched and would go stale forever.
        let canDeferInvalidation = needsFullInvalidation
            && changeSet.removed.isEmpty && changeSet.added.isEmpty
            && !changeSet.layoutChanged.isEmpty
            && changeSet.layoutChanged.allSatisfy { $0.prevIdx == $0.nextIdx && visibleCells[$0.prevIdx] != nil }

        // Capture per-block diff inputs for every layout-changed survivor BEFORE
        // workingRange.invalidateAll() wipes the ring buffer — the old fragments are only
        // readable from WorkingRange right now; once invalidated, recovering them needs a full
        // re-measure, the exact O(item length) cost this diff avoids.
        var blockDiffInputs: [Int: (previousTable: NodeTable, newTable: NodeTable, previousFragments: [Fragment])] = [:]
        if needsFullInvalidation {
            for e in changeSet.layoutChanged {
                guard let wrEntry = workingRange.entry(at: e.prevIdx) else { continue }
                blockDiffInputs[e.prevIdx] = (e.prev, e.next, wrEntry.fragments)
                evictChangedResidentRasters(previousTable: e.prev, newTable: e.next, nextIdx: e.nextIdx)
            }

            if !canDeferInvalidation {
                workingRange.invalidateAll()
                let pipeline = self.pipeline
                Task { await pipeline.markInvalidated() }
            }
        }

        return DiffPlan(
            survivors: survivors,
            needsFullInvalidation: needsFullInvalidation,
            canDeferInvalidation: canDeferInvalidation,
            blockDiffInputs: blockDiffInputs
        )
    }

    /// A same-id in-place edit changes a block's content but not its `BlockKey` — the key is
    /// `itemID + blockID`, content-independent (see `BlockKey`). The resident tier
    /// (`visibleBlockStore`) still holds the pre-edit raster under that key. If this edit later
    /// falls to the full-refresh path (`RenderPipeline`), the pipeline writes the fresh raster to
    /// `frozenBitmapStore`, but `buildSyncMap` reads the resident tier first and would serve the
    /// stale one — the cell keeps the old pixels. So drop the stale resident rasters here.
    ///
    /// Evict ONLY blocks whose `contentHash` changed. An unchanged block must stay resident:
    /// on first paint `buildSyncMap` promotes it out of `frozenBitmapStore` and evicts it there,
    /// so the resident tier is its only copy — evicting it would blank the block. VelocityUI-93um.
    private func evictChangedResidentRasters(previousTable: NodeTable, newTable: NodeTable, nextIdx: Int) {
        guard nextIdx < items.count else { return }
        let itemID = items[nextIdx].id
        let width = measureWidth(for: containerWidth)
        guard let (prevBlocks, _) = flatBlocks(for: previousTable, itemID: itemID, width: width),
              let (newBlocks, _) = flatBlocks(for: newTable, itemID: itemID, width: width)
        else { return }
        var newHashByID: [BlockID: Int] = [:]
        for b in newBlocks { if let id = b.blockID { newHashByID[id] = b.contentHash } }
        var stale: Set<BlockKey> = []
        for b in prevBlocks {
            guard let id = b.blockID else { continue }
            if newHashByID[id] != b.contentHash { stale.insert(b.key) }
        }
        if !stale.isEmpty { environment.visibleBlockStore.evict(stale) }
    }

    private func commitSnapshot(
        _ nextSnapshot: LayoutSnapshot,
        nextTables: [NodeTable],
        oldFrames: [CGRect],
        survivors: [(prevIdx: Int, nextIdx: Int)]
    ) {
        snapshot = nextSnapshot
        tables = nextTables
        rebuildFrames(oldFrames: oldFrames, survivors: survivors)
    }

    /// Reconciles `visibleCells` against the new `tables`/`plan` — either the full reuse/recycle
    /// loop (when layout-impacting changes exist) or a lightweight appearance/media re-fetch.
    /// Returns whether every layout-changed survivor resolved via the in-place block-diff fast
    /// path (no WorkingRange invalidation needed) — set only by the fully-resolved fast path,
    /// gating the `lastNotifiedLeadingIndex` reset in `finishItemsChange`.
    private func reconcileVisibleCells(changeSet: ChangeSet, plan: DiffPlan) -> Bool {
        guard plan.needsFullInvalidation else {
            refreshAppearanceAndMediaChanged(changeSet: changeSet)
            return false
        }
        return reuseOrRecycleVisibleCells(changeSet: changeSet, plan: plan)
    }

    private func refreshAppearanceAndMediaChanged(changeSet: ChangeSet) {
        for e in changeSet.appearanceChanged {
            guard let cell = visibleCells[e.nextIdx],
                  let wrEntry = workingRange.entry(at: e.nextIdx) else { continue }
            let freshFragments = extractFragments(table: e.next, layout: wrEntry.layout)
            cell.cancelPendingMedia()
            spawnMediaFetches(for: cell, fragments: freshFragments, itemID: e.next.itemID)
        }
        for e in changeSet.mediaChanged {
            guard let cell = visibleCells[e.nextIdx],
                  let wrEntry = workingRange.entry(at: e.nextIdx) else { continue }
            let freshFragments = extractFragments(table: e.next, layout: wrEntry.layout)
            cell.cancelPendingMedia()
            spawnMediaFetches(for: cell, fragments: freshFragments, itemID: e.next.itemID)
        }
    }

    private enum CellReuseResult {
        case recycled
        case kept(nextIdx: Int, blockDiffResolved: Bool, workingRangeCommit: (layout: ResolvedLayout, fragments: [Fragment])?)
    }

    private func reuseOrRecycleVisibleCells(changeSet: ChangeSet, plan: DiffPlan) -> Bool {
        // reuseDecision gates recycling explicitly rather than trusting that survivors always
        // match identity — makes the decision rule the one source of truth and testable.
        var survivorByPrevIdx: [Int: Int] = [:]
        survivorByPrevIdx.reserveCapacity(plan.survivors.count)
        for s in plan.survivors { survivorByPrevIdx[s.prevIdx] = s.nextIdx }

        var keptCells: [Int: RenderCell] = [:]
        keptCells.reserveCapacity(visibleCells.count)
        // Indices the block-diff path below already resolved synchronously — excluded from
        // the _pendingFragmentIndices re-enroll so refineKnownFrames doesn't redo the work.
        var blockDiffResolvedIndices: Set<Int> = []
        // WorkingRange patches for the fast path, applied after the loop iff every
        // layoutChanged entry resolved — a synthetic ResolvedLayout mirroring what
        // extractFragments would derive, so later appearance/media classification stays correct.
        var blockDiffWorkingRangeCommits: [Int: (layout: ResolvedLayout, fragments: [Fragment])] = [:]
        let width = measureWidth(for: containerWidth)
        let scale = max(1, traitCollection.displayScale)

        for (prevIdx, cell) in visibleCells {
            switch reconcileCell(
                prevIdx: prevIdx, cell: cell, survivorByPrevIdx: survivorByPrevIdx,
                blockDiffInputs: plan.blockDiffInputs, canDeferInvalidation: plan.canDeferInvalidation,
                width: width, scale: scale
            ) {
            case .recycled:
                continue
            case .kept(let nextIdx, let blockDiffResolved, let workingRangeCommit):
                keptCells[nextIdx] = cell
                if blockDiffResolved {
                    blockDiffResolvedIndices.insert(nextIdx)
                    if let workingRangeCommit {
                        blockDiffWorkingRangeCommits[nextIdx] = workingRangeCommit
                    }
                }
            }
        }
        visibleCells = keptCells

        return resolveDeferredInvalidation(
            changeSet: changeSet, plan: plan, keptCells: keptCells,
            blockDiffResolvedIndices: blockDiffResolvedIndices,
            blockDiffWorkingRangeCommits: blockDiffWorkingRangeCommits
        )
    }

    /// Resolves the deferred invalidation decision `decideInvalidation` only established
    /// eligibility for: whether each layout-changed entry actually resolved via block-diff is
    /// known only now, after the reuse loop ran. All-resolved: patch WorkingRange directly,
    /// skipping full-window invalidate + pipeline re-measure. Partial failure: fall back to full
    /// invalidate + markInvalidated. Also re-enrolls kept-but-unresolved indices into
    /// `_pendingFragmentIndices` so `refineKnownFrames` refreshes their content once WorkingRange
    /// recommits — without this, a same-id survivor freezes on stale content until it re-mounts.
    private func resolveDeferredInvalidation(
        changeSet: ChangeSet,
        plan: DiffPlan,
        keptCells: [Int: RenderCell],
        blockDiffResolvedIndices: Set<Int>,
        blockDiffWorkingRangeCommits: [Int: (layout: ResolvedLayout, fragments: [Fragment])]
    ) -> Bool {
        var tookInPlaceFastPath = false
        if plan.canDeferInvalidation {
            if blockDiffResolvedIndices.count == changeSet.layoutChanged.count {
                for (nextIdx, commit) in blockDiffWorkingRangeCommits {
                    workingRange.commit(commit.layout, commit.fragments, at: nextIdx)
                }
                tookInPlaceFastPath = true
            } else {
                workingRange.invalidateAll()
                let pipeline = self.pipeline
                Task { await pipeline.markInvalidated() }
            }
        }

        _pendingFragmentIndices.removeAll(keepingCapacity: true)
        _pendingFragmentIndices.formUnion(keptCells.keys.filter { !blockDiffResolvedIndices.contains($0) })

        return tookInPlaceFastPath
    }

    /// One visible cell's reuse decision for `reuseOrRecycleVisibleCells`'s loop: recycle it back
    /// to the pool, or keep it (detached, re-attached later by `updateVisibleCells`'s mount loop)
    /// and attempt the per-block diff fast path.
    private func reconcileCell(
        prevIdx: Int,
        cell: RenderCell,
        survivorByPrevIdx: [Int: Int],
        blockDiffInputs: [Int: (previousTable: NodeTable, newTable: NodeTable, previousFragments: [Fragment])],
        canDeferInvalidation: Bool,
        width: CGFloat,
        scale: CGFloat
    ) -> CellReuseResult {
        guard let nextIdx = survivorByPrevIdx[prevIdx], nextIdx < tables.count,
              reuseDecision(oldID: cell.currentItemID, newID: tables[nextIdx].itemID) == .inPlace
        else {
            cell.layer.removeFromSuperlayer()
            returnToPool(cell)
            return .recycled
        }

        // Detach without repositioning: survivor indices can shift relative to items still to be
        // mounted this pass (e.g. a prepend). updateVisibleCells' mount loop re-attaches in
        // ascending visible-index order to preserve z-order.
        cell.layer.removeFromSuperlayer()

        // Per-block diff: unchanged blocks reused verbatim from FrozenBitmapStore, only the hot
        // tail touched. Returns nil when it can't guarantee correct content cheaply, falling
        // through to the full-refresh path.
        guard let inputs = blockDiffInputs[prevIdx], nextIdx < items.count,
              let result = applyInPlaceBlockDiff(
                  previousTable: inputs.previousTable,
                  previousFragments: inputs.previousFragments,
                  newTable: inputs.newTable,
                  itemID: items[nextIdx].id,
                  width: width,
                  scale: scale
              )
        else {
            return .kept(nextIdx: nextIdx, blockDiffResolved: false, workingRangeCommit: nil)
        }

        let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: nextIdx, newHeight: result.height)
        applyContentHeightDelta(delta)
        estimatedIndices.remove(nextIdx)
        cell.layer.frame = resolvedFrames[nextIdx]
        // Merge image cache hits with the block-diff's freshly-resolved text bitmaps — fragment
        // ids never collide across content kinds within one item's NodeTable, so a plain
        // overwrite-merge is safe.
        var syncMap = buildSyncMap(for: result.fragments, itemID: inputs.newTable.itemID)
        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
        let entering = cell.updateBlockViewport(
            fragments: result.fragments,
            viewportInCell: blockViewport(for: cell.layer.frame),
            synchronousContent: syncMap
        )
        spawnMediaFetches(for: cell, fragments: entering, itemID: inputs.newTable.itemID, syncMap: syncMap)

        var workingRangeCommit: (layout: ResolvedLayout, fragments: [Fragment])?
        if canDeferInvalidation {
            let syntheticLayout = makeSyntheticWorkingRangeLayout(
                table: inputs.newTable, fragments: result.fragments, width: width, height: result.height
            )
            workingRangeCommit = (syntheticLayout, result.fragments)
        }
        return .kept(nextIdx: nextIdx, blockDiffResolved: true, workingRangeCommit: workingRangeCommit)
    }

    /// Reset reachEnd gate if item count grew (new page arrived). On the fully-resolved fast
    /// path, WorkingRange was patched directly (not invalidated), so nothing needs a pipeline
    /// re-measure — re-notifying would just spawn a wasted Task that early-returns inside
    /// onIndexBoundary.
    private func finishItemsChange(itemCountGrew: Bool, tookInPlaceFastPath: Bool) {
        if itemCountGrew {
            reachEndFired = false
        }
        if !tookInPlaceFastPath {
            lastNotifiedLeadingIndex = -1
        }
        syncContentSize()
        setNeedsLayout()
    }

    // MARK: - In-place per-block diff

    /// Per-block diff for one `.inPlace` survivor: builds previous/new `[Block]` lists from each
    /// side's flat `NodeTable`, diffs them, and re-measures only changed blocks — freezing text
    /// blocks into `environment.frozenBitmapStore` once done growing. Returns the item's new
    /// height, its repositioned fragments, and a fragment-id→bitmap map the caller merges into
    /// `synchronousContent` so `applyLayout` paints real pixels instead of leaving text blank.
    /// `nil` when the update can't be optimized safely — caller falls back to the
    /// `_pendingFragmentIndices` full-refresh path.
    ///
    /// `previousFragments` must be the real fragments `extractFragments` produced last time this
    /// item was measured, captured before `invalidateAll()` — the only source of the old
    /// content's real per-block heights.
    ///
    /// `itemID` is `Item.ID`, not `NodeTable.itemID` (`AnyHashable`, not `Sendable`) — `.inPlace`
    /// guarantees both tables share identity, so one `itemID` covers both `flatBlocks` calls.
    private func applyInPlaceBlockDiff<ID: Hashable & Sendable>(
        previousTable: NodeTable,
        previousFragments: [Fragment],
        newTable: NodeTable,
        itemID: ID,
        width: CGFloat,
        scale: CGFloat
    ) -> (height: CGFloat, fragments: [Fragment], textBitmaps: [Int: CGImage])? {
        guard let (previousBlocks, _) = flatBlocks(for: previousTable, itemID: itemID, width: width),
              let (newBlocks, spacing) = flatBlocks(for: newTable, itemID: itemID, width: width),
              !newBlocks.isEmpty
        else { return nil }

        let trailingIndex = newBlocks.count - 1
        let d = diff(previous: previousBlocks, new: newBlocks)
        let store = environment.frozenBitmapStore
        let residentStore = environment.visibleBlockStore
        let themeSnapshot = environment.highlightRegistry.themeSnapshot
        let codeBodyIdentity = CodeBodyRasterIdentity(
            themeGeneration: themeSnapshot.generation,
            scale: scale
        )
        let previousFragmentByID = Dictionary(uniqueKeysWithValues: previousFragments.map { ($0.id, $0) })
        // `first(where:)` per code block would make an N-code-block message do O(N²)
        // reconciliation; a single upfront dictionary keeps this O(N) overall.
        let previousBlockByKey = Dictionary(previousBlocks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        func previousCodeDescriptor(for block: Block) -> CodeBlockDescriptor? {
            guard let previous = previousBlockByKey[block.key],
                  case .codeBlock(let descriptor) = previousTable.nodes[previous.fragment.id]
            else { return nil }
            return descriptor
        }

        // A code block's body raster is cached under its `.codeBody` part identity, not the
        // block's own key — `RenderPipeline.rasterizeTextArtifacts` uses this same
        // `codePartID(..., part: .codeBody)` key so a raster produced on one path is a hit on
        // the other.
        func codeBodyKey(for block: Block) -> BlockKey {
            BlockKey(itemID: itemID, blockID: codePartID(owner: block.blockID, nodeIndex: block.fragment.id, part: .codeBody))
        }

        // Measures (+ rasterizes) one active text block via the `freeze(_:)` primitive and keeps
        // its artifact in the resident tier. A fresh function-scoped `cache` dict is passed on
        // every call so this always recomputes — `store` is the persistent cache, consulted
        // separately below for the genuinely-unchanged case.
        func measureAndMaybeFreeze(_ block: Block) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text(let descriptor) = block.fragment.content else { return nil }
            // On seal, reuse the composited bitmap the hot-append path already produced instead
            // of a fresh measure/rasterize. catchUpAndFinalize first re-appends the descriptor's
            // current content so a block that grew further this round is caught up before the
            // seal check. Always tears down the entry so a stale hot rasterizer never lingers.
            if let sealed = environment.hotBlockRasterizerStore.catchUpAndFinalize(
                block.key, descriptor: descriptor, width: block.width, scale: scale, contentHash: block.contentHash
            ) {
                residentStore.store(sealed.image, size: sealed.size, for: block.key)
                return (sealed.size.height, sealed.image)
            }
            // A code block body that was never hot in this session (e.g. loaded already-sealed
            // from history) never touched HotBlockRasterizerStore above -- it needs the real
            // syntax-highlighted, non-wrapping raster, not the generic freeze() path below (which
            // would rasterize the plain, container-clipped TextDescriptor Flattener produced).
            if case .body(let chrome) = descriptor.codeBlockRole {
                let lines = descriptor.content.components(separatedBy: "\n")[...]
                let theme = themeSnapshot.theme
                let grammar = environment.highlightRegistry.grammar(for: LanguageID(fenceInfo: chrome.language))
                let colorRuns = TreeSitterHighlighter().colorRuns(for: lines, grammar: grammar, theme: theme)
                let result = rasterizeCodeBlockSync(
                    lines: lines, colorRuns: colorRuns, font: descriptor.font, theme: theme, scale: scale,
                    measure: { [self] d, w in measureTextSync(d, width: w) }
                )
                guard let bitmap = result.image else { return (result.size.height, nil) }
                residentStore.store(
                    bitmap,
                    size: result.size,
                    for: codeBodyKey(for: block),
                    codeBodyIdentity: codeBodyIdentity
                )
                return (result.size.height, bitmap)
            }
            var localCache: [BlockKey: FreezeState] = [:]
            // `freeze(_:)` always measures before rasterizing, but on a rasterize failure
            // (degenerate size, e.g. a still-empty just-appended block) returns bare `.hot` with
            // no size. Capture the measured size via the injected `measure` closure so the `.hot`
            // fallback below can reuse it — a second `measureTextSync` call there would
            // double-count this block's cost for the same update.
            var measuredSize: CGSize?
            let state = freeze(
                block, scale: scale, cache: &localCache,
                measure: { [self] descriptor, w in
                    let s = measureTextSync(descriptor, width: w)
                    measuredSize = s
                    return s
                },
                rasterize: { [self] descriptor, size, s in
                    _testHooks.blockDiffRasterizeCallCount += 1
                    return rasterizeText(descriptor, size: size, scale: s)
                }
            )
            switch state {
            case .frozen(let size, let bitmap):
                residentStore.store(bitmap, size: size, for: block.key)
                return (size.height, bitmap)
            case .hot:
                // Rasterization failed on a degenerate size — freeze() intentionally returns
                // uncached .hot so a later call can retry; `measuredSize` was already captured
                // above. No bitmap: RenderCell paints blank instead of a stale/wrong image for
                // this fragment id until a later round rasterizes successfully.
                return (measuredSize?.height ?? 0, nil)
            }
        }

        // Hot-append path for the trailing volatile block — O(appended) cost via
        // HotBlockRasterizerStore instead of O(block size) measure/rasterize. Never persists
        // into FrozenBitmapStore since the block is still growing; artifact stays resident.
        func measureAndRasterizeHot(_ block: Block) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text(let descriptor) = block.fragment.content else { return nil }
            _testHooks.blockDiffHotAppendCallCount += 1
            let result = environment.hotBlockRasterizerStore.append(
                descriptor, width: block.width, scale: scale, contentHash: block.contentHash, for: block.key
            )
            if let image = result.image {
                residentStore.store(image, size: CGSize(width: block.width, height: result.height), for: block.key)
            }
            return (result.height, result.image)
        }

        var heights = [CGFloat](repeating: 0, count: newBlocks.count)
        var localFragmentFrames = [CGRect](repeating: .null, count: newBlocks.count)
        var textBitmaps: [Int: CGImage] = [:]
        var resolvedIndices = Set<Int>()

        func resolveDeterministicGeometry(_ block: Block) -> LeafGeometryResolution? {
            resolveLeafGeometry(
                block.contract.geometry,
                presentation: block.contract.presentation,
                frame: newTable.frame(at: block.fragment.id),
                proposedWidth: width
            )
        }

        func recordTextResult(
            _ result: (height: CGFloat, bitmap: CGImage?), for block: Block, at index: Int
        ) {
            heights[index] = result.height
            // The frame width must equal the bitmap's own width, not the full cell width. Short
            // text (a heading, a `---` rule) is rasterised tight to its glyphs, so a full-width
            // frame makes contentsGravity=resize stretch that narrow bitmap sideways — the
            // "heading in a stretched font" bug. Full-width bitmaps (wrapped prose, hot blocks
            // rasterised at block.width) already match this, so it's a no-op for them. Mirrors the
            // initial-layout path, which already frames text to its measured width.
            let frameWidth = result.bitmap.map { CGFloat($0.width) / scale } ?? width
            localFragmentFrames[index] = CGRect(x: 0, y: 0, width: frameWidth, height: result.height)
            textBitmaps[block.fragment.id] = result.bitmap
        }

        func recordGeometry(_ geometry: LeafGeometryResolution, at index: Int) {
            heights[index] = geometry.slotSize.height
            localFragmentFrames[index] = geometry.contentFrame
        }

        for match in d.reused + d.moved {
            let block = newBlocks[match.newIndex]
            resolvedIndices.insert(match.newIndex)
            if d.hot.contains(match.newIndex), case .text = block.fragment.content {
                guard let result = measureAndRasterizeHot(block) else { return nil }
                recordTextResult(result, for: block, at: match.newIndex)
                continue
            }
            if case .text(let descriptor) = block.fragment.content {
                // Reads against the same key the tree-sitter `.body` branch above writes to
                // (`codeBodyKey`) — the generic `block.key` is only ever right for non-code text.
                let readKey: BlockKey
                if case .body = descriptor.codeBlockRole {
                    readKey = codeBodyKey(for: block)
                } else {
                    readKey = block.key
                }
                if let sealed = environment.hotBlockRasterizerStore.catchUpAndFinalize(
                       block.key,
                       descriptor: descriptor,
                       width: block.width,
                       scale: scale,
                       contentHash: block.contentHash
                   ) {
                    residentStore.store(sealed.image, size: sealed.size, for: block.key)
                    recordTextResult(
                        (sealed.size.height, sealed.image), for: block, at: match.newIndex
                    )
                } else {
                    if residentStore.bitmap(for: readKey) == nil {
                        residentStore.promote([readKey], from: store)
                    }
                    let cached: (image: CGImage, size: CGSize)?
                    if case .body = descriptor.codeBlockRole {
                        cached = residentStore.codeBodyRaster(
                            for: readKey,
                            identity: codeBodyIdentity
                        )
                    } else if let size = residentStore.size(for: readKey),
                              let bitmap = residentStore.bitmap(for: readKey) {
                        cached = (bitmap, size)
                    } else {
                        cached = nil
                    }
                    if let cached {
                        recordTextResult((cached.size.height, cached.image), for: block, at: match.newIndex)
                    } else {
                        // Recompute after eviction or a raster-identity mismatch.
                        guard let result = measureAndMaybeFreeze(block) else { return nil }
                        recordTextResult(result, for: block, at: match.newIndex)
                    }
                }
            } else {
                if let geometry = resolveDeterministicGeometry(block) {
                    recordGeometry(geometry, at: match.newIndex)
                } else {
                    // Measured non-text has no synchronous geometry contract. Preserve the real
                    // prior fragment just as the pre-resolver path did for unchanged content.
                    guard let previousFrame = previousFragmentByID[
                        previousBlocks[match.previousIndex].fragment.id
                    ]?.frame else { return nil }
                    heights[match.newIndex] = previousFrame.height
                    localFragmentFrames[match.newIndex] = CGRect(
                        x: previousFrame.minX, y: 0,
                        width: previousFrame.width, height: previousFrame.height
                    )
                }
            }
        }
        for i in d.updated + d.inserted {
            resolvedIndices.insert(i)
            let block = newBlocks[i]
            if case .text = block.fragment.content {
                let isHot = d.hot.contains(i)
                let result = (isHot && environment.hotBlockRasterizeEnabled)
                    ? measureAndRasterizeHot(block)
                    : measureAndMaybeFreeze(block)
                guard let result else { return nil }
                recordTextResult(result, for: block, at: i)
            } else {
                guard let geometry = resolveDeterministicGeometry(block) else { return nil }
                recordGeometry(geometry, at: i)
            }
        }
        // Positional fallback: exposes the volatile tail only through `hot`, without also
        // classifying that index as updated or reused.
        for i in d.hot where !resolvedIndices.contains(i) {
            let block = newBlocks[i]
            if case .text = block.fragment.content {
                let result = environment.hotBlockRasterizeEnabled
                    ? measureAndRasterizeHot(block)
                    : measureAndMaybeFreeze(block)
                guard let result else { return nil }
                recordTextResult(result, for: block, at: i)
            } else {
                guard let geometry = resolveDeterministicGeometry(block) else { return nil }
                recordGeometry(geometry, at: i)
            }
        }

        if !d.removed.isEmpty {
            var removed = Set(d.removed)
            // A removed code block's header/body rasters live under their own `codePartID`
            // keys, not `block.key` — evicting only `block.key` leaves those part-keyed rasters
            // orphaned: `VisibleBlockStore` has no LRU, so they'd stay resident indefinitely,
            // and `FrozenBitmapStore` would only reclaim them once its own LRU happens to evict
            // that key under memory pressure, not because the block was actually removed.
            for key in d.removed {
                guard let block = previousBlockByKey[key],
                      case .codeBlock = previousTable.nodes[block.fragment.id]
                else { continue }
                removed.insert(BlockKey(itemID: itemID, blockID: codePartID(owner: block.blockID, nodeIndex: block.fragment.id, part: .codeHeader)))
                removed.insert(BlockKey(itemID: itemID, blockID: codePartID(owner: block.blockID, nodeIndex: block.fragment.id, part: .codeBody)))
            }
            store.evict(removed)
            residentStore.evict(removed)
            environment.hotBlockRasterizerStore.evict(removed)
        }

        var cursor: CGFloat = 0
        var fragments: [Fragment] = []
        fragments.reserveCapacity(newBlocks.count + 2)
        for (i, block) in newBlocks.enumerated() {
            let localFrame = localFragmentFrames[i].isNull
                ? CGRect(x: 0, y: 0, width: width, height: heights[i])
                : localFragmentFrames[i]
            if case .codeBlock(let descriptor) = newTable.nodes[block.fragment.id] {
                let headerPartID = codePartID(owner: block.blockID, nodeIndex: block.fragment.id, part: .codeHeader)
                let headerKey = BlockKey(itemID: itemID, blockID: headerPartID)
                let headerUnchanged = previousCodeDescriptor(for: block).map {
                    codeBlockRenderPartHash($0, part: .codeHeader)
                        == codeBlockRenderPartHash(descriptor, part: .codeHeader)
                } ?? false
                let residentHeader = headerUnchanged ? residentStore.bitmap(for: headerKey) : nil
                let frozenHeader = headerUnchanged && residentHeader == nil ? store.bitmap(for: headerKey) : nil
                let cachedHeader = residentHeader ?? frozenHeader
                let cachedHeaderSize = headerUnchanged
                    ? residentStore.size(for: headerKey)
                        ?? store.size(for: headerKey)
                        ?? previousFragmentByID[codeHeaderFragmentID(nodeIndex: block.fragment.id)]?.frame.size
                    : nil
                let headerSize = cachedHeaderSize ?? measureTextSync(descriptor.headerText, width: width)
                let headerBitmap = cachedHeader ?? rasterizeText(descriptor.headerText, size: headerSize, scale: scale)
                let headerWidth = cachedHeaderSize?.width ?? headerBitmap.map { CGFloat($0.width) / scale } ?? headerSize.width
                let bodyFrame = localFrame.offsetBy(dx: 0, dy: cursor + headerSize.height)
                let total = CGRect(
                    x: 0, y: cursor, width: max(width, bodyFrame.width),
                    height: headerSize.height + localFrame.height
                )
                let materialized = materializeCodeBlockFragments(
                    descriptor: descriptor,
                    nodeIndex: block.fragment.id,
                    ownerBlockID: block.blockID,
                    backgroundFrame: total,
                    headerFrame: CGRect(x: 0, y: cursor, width: headerWidth, height: headerSize.height),
                    bodyFrame: bodyFrame
                )
                fragments.append(contentsOf: materialized)
                if let headerBitmap {
                    residentStore.store(headerBitmap, size: headerSize, for: headerKey)
                    if frozenHeader != nil { store.evict([headerKey]) }
                    textBitmaps[materialized[1].id] = headerBitmap
                }
                cursor += total.height
                if i < trailingIndex { cursor += spacing }
                continue
            }
            let frame = localFrame.offsetBy(dx: 0, dy: cursor)
            fragments.append(Fragment(
                id: block.fragment.id,
                blockID: block.blockID,
                content: block.fragment.content,
                frame: frame
            ))
            cursor += heights[i]
            if i < trailingIndex { cursor += spacing }
        }
        return (cursor, fragments, textBitmaps)
    }

    /// Reconstructs the flat root layout with explicit code-card children, so a later
    /// `extractFragments(table:layout:)` sees the same background/header/body render plan.
    private func makeSyntheticWorkingRangeLayout(
        table: NodeTable, fragments: [Fragment], width: CGFloat, height: CGFloat
    ) -> ResolvedLayout {
        let byID = Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, $0) })
        let children = table.children(of: 0).compactMap { nodeIndex -> ResolvedLayout? in
            guard nodeIndex < table.nodes.count else { return nil }
            guard case .codeBlock = table.nodes[nodeIndex] else {
                return byID[nodeIndex].map { ResolvedLayout(totalFrame: $0.frame, nodeIndex: nodeIndex) }
            }
            guard let background = byID[codeBackgroundFragmentID(nodeIndex: nodeIndex)],
                  let header = byID[codeHeaderFragmentID(nodeIndex: nodeIndex)],
                  let body = byID[nodeIndex]
            else { return nil }
            let origin = background.frame.origin
            func local(_ fragment: Fragment) -> CGRect {
                fragment.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            }
            return ResolvedLayout(
                totalFrame: background.frame,
                children: [
                    ResolvedLayout(totalFrame: local(background), nodeIndex: nodeIndex, renderPart: .codeBackground),
                    ResolvedLayout(totalFrame: local(header), nodeIndex: nodeIndex, renderPart: .codeHeader),
                    ResolvedLayout(totalFrame: local(body), nodeIndex: nodeIndex, renderPart: .codeBody),
                ],
                nodeIndex: nodeIndex
            )
        }
        return ResolvedLayout(
            totalFrame: CGRect(x: 0, y: 0, width: width, height: height),
            children: children,
            nodeIndex: 0
        )
    }

    /// Recognizes the one item shape this diff optimizes: a root `.vstack` whose direct children
    /// are all leaves — no nesting, no hstack/zstack — the "VStack of streaming message blocks"
    /// shape a chat message produces. Returns `nil` for any other shape, so the caller falls
    /// back to the full-refresh path instead of a possibly-wrong optimization.
    ///
    /// Blocks are positioned 0-height placeholders at `width`; real height is filled in by the
    /// caller from measurement. `itemID` is the caller's real `Item.ID`, not `table.itemID`.
    private func flatBlocks<ID: Hashable & Sendable>(
        for table: NodeTable, itemID: ID, width: CGFloat
    ) -> (blocks: [Block], spacing: CGFloat)? {
        guard !table.nodes.isEmpty, case .vstack(let vstackDescriptor) = table.nodes[0] else { return nil }
        let childIndices = table.children(of: 0)
        // Every node beyond the root must be a direct child of it — if any node is NOT (i.e. a
        // grandchild from a nested container), childIndices.count is strictly less than
        // nodes.count - 1, catching nesting without walking parentIndices for every node.
        guard !childIndices.isEmpty, childIndices.count == table.nodes.count - 1 else { return nil }

        var blocks: [Block] = []
        blocks.reserveCapacity(childIndices.count)
        for (position, nodeIndex) in childIndices.enumerated() {
            guard let contract = table.blockRenderContract(
                at: nodeIndex, itemID: itemID, positionalIndex: position
            ) else { return nil }
            let frame = CGRect(x: 0, y: 0, width: width, height: 0)
            blocks.append(Block(contract: contract, id: nodeIndex, frame: frame))
        }
        return (blocks, vstackDescriptor.spacing)
    }

    /// Emits just the BlockKeys for the flat-vstack-of-leaves shape `flatBlocks` recognizes,
    /// without building any `Block`/`Fragment`/`ResolvedLayout` — scroll-path bookkeeping needs
    /// only the keys, and a full `Block` alloc on every keep-range crossing during a fling would
    /// violate the zero-allocation scroll-path invariant. Mirrors `flatBlocks`' guards exactly.
    /// Returns `true` when it inserted the full flat key set, `false` on a non-flat shape.
    ///
    /// A code block's header/body rasters live under their own `codePartID(..., part:)` keys
    /// (see `codeBodyKey` in `applyInPlaceBlockDiff`), separate from the block's own key — those
    /// part keys must also be emitted here or `updateVisibleCells` never demotes/evicts them when
    /// the block leaves the visible range.
    @discardableResult
    func flatBlockKeys<ID: Hashable & Sendable>(
        for table: NodeTable, itemID: ID, into keys: inout Set<BlockKey>
    ) -> Bool {
        guard !table.nodes.isEmpty, case .vstack = table.nodes[0] else { return false }
        let childIndices = table.children(of: 0)
        guard !childIndices.isEmpty, childIndices.count == table.nodes.count - 1 else { return false }
        // Validate the whole shape is flat first, without touching `keys` — a nested container
        // found partway through must bail without partially mutating the caller's accumulator.
        for nodeIndex in childIndices where !table.isBlockLeaf(at: nodeIndex) { return false }
        for (position, nodeIndex) in childIndices.enumerated() {
            let ownerBlockID = table.blockID(at: nodeIndex)
            let key = ownerBlockID.map { BlockKey(itemID: itemID, blockID: $0) }
                ?? BlockKey(itemID: itemID, index: position)
            keys.insert(key)
            if case .codeBlock = table.nodes[nodeIndex] {
                keys.insert(BlockKey(itemID: itemID, blockID: codePartID(owner: ownerBlockID, nodeIndex: nodeIndex, part: .codeHeader)))
                keys.insert(BlockKey(itemID: itemID, blockID: codePartID(owner: ownerBlockID, nodeIndex: nodeIndex, part: .codeBody)))
            }
        }
        return true
    }

    /// Synchronous text measurement for the in-place path. The scroll/bind path must never
    /// `await`, so this can't go through the pooled, actor-isolated `TextMeasurementPool`.
    /// Allocates fresh TextKit objects per call instead — bounded, since this path touches at
    /// most one or two text blocks per update.
    private func measureTextSync(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
        _testHooks.blockDiffMeasureCallCount += 1
        return TextMeasurementContext().measure(descriptor, width: width)
    }

    // MARK: - Hot-block side-channel during an active scroll gesture

    /// Whether a scroll gesture is currently in progress — the condition `growHotBlock(_:)`
    /// gates on. Wraps UIKit's read-only gesture signals behind one property so tests can
    /// override it via `_debugGestureActiveOverride` without a live touch.
    private var isGestureActive: Bool {
        if let override = _testHooks.gestureActiveOverride { return override }
        return isTracking || isDragging || isDecelerating
    }

    /// Grows the trailing hot block of `item` directly, bypassing the full `items` diff/relayout
    /// path. Call this instead of reassigning `items` on every streaming token while a scroll
    /// gesture is active, passing the item's current value:
    ///
    ///     message.markdownParser.append(token)
    ///     if feed.isTracking || feed.isDragging || feed.isDecelerating {
    ///         _ = feed.growHotBlock(message)   // false: parser still holds the true content,
    ///     } else {                             // next `items =` assignment catches up
    ///         feed.items = messages
    ///     }
    ///
    /// Only applies when `item` is the last element of `items` (bottom-growing single-message
    /// case); other growth always falls through to a normal `items =` assignment.
    ///
    /// Internally re-runs `applyInPlaceBlockDiff`, scoped to just this item, diffing the whole
    /// block list every call so a block-boundary event (new paragraph/image/rule) is handled
    /// live during the gesture, not deferred. `tables`/`WorkingRange` stay continuously in sync,
    /// so nothing needs reconciling at gesture end — the next `items =` assignment finds
    /// `HotBlockRasterizerStore` already at the final content, no flash.
    ///
    /// - Returns: `true` if the side-channel painted this update (safe to skip `items =`).
    ///   `false` if the caller must fall back to `items =` — no gesture active, `item` isn't the
    ///   last item, its cell/WorkingRange isn't primed yet, or its shape isn't optimizable.
    @discardableResult
    @MainActor
    public func growHotBlock(_ item: Item) -> Bool {
        guard isGestureActive else { return false }
        guard let lastIdx = items.indices.last, items[lastIdx].id == item.id else { return false }
        guard lastIdx < tables.count, lastIdx < resolvedFrames.count else { return false }
        guard let cell = visibleCells[lastIdx] else { return false }
        guard let builder = cellBuilder else { return false }
        guard let previousEntry = workingRange.entry(at: lastIdx) else { return false }

        let width = measureWidth(for: containerWidth)
        let scale = max(1, traitCollection.displayScale)
        let previousTable = tables[lastIdx]
        let newTable = flatten(builder(item), itemID: item.id, contentSizeCategory: contentSizeCategory)

        guard let result = applyInPlaceBlockDiff(
            previousTable: previousTable,
            previousFragments: previousEntry.fragments,
            newTable: newTable,
            itemID: item.id,
            width: width,
            scale: scale
        ) else { return false }

        let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: lastIdx, newHeight: result.height)
        applyContentHeightDelta(delta)
        cell.layer.frame = resolvedFrames[lastIdx]

        var syncMap = buildSyncMap(for: result.fragments, itemID: newTable.itemID)
        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
        let entering = cell.updateBlockViewport(
            fragments: result.fragments,
            viewportInCell: blockViewport(for: cell.layer.frame),
            synchronousContent: syncMap
        )
        spawnMediaFetches(for: cell, fragments: entering, itemID: newTable.itemID, syncMap: syncMap)

        // Keep tables/WorkingRange continuously in sync with what's on screen — this is what
        // makes the gesture-end reconcile free. Mirrors itemsDidChange's fast-path commit shape.
        tables[lastIdx] = newTable
        let syntheticLayout = makeSyntheticWorkingRangeLayout(
            table: newTable, fragments: result.fragments, width: width, height: result.height
        )
        workingRange.commit(syntheticLayout, result.fragments, at: lastIdx)

        _testHooks.growHotBlockSuccessCount += 1
        return true
    }
}
#endif
