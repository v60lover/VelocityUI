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
                _pendingPipelineInvalidation = true
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
                _pendingPipelineInvalidation = true
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
                  scale: scale,
                  codeStreamDelivery: { [weak cell] fragmentID, content in
                      cell?.applyCodeBodyTile(id: fragmentID, content: content, for: inputs.newTable.itemID)
                  }
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
        var syncMap = buildSyncMap(for: result.fragments, table: inputs.newTable, ordinals: inputs.newTable.leafOrdinals())
        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
        let codeMap = result.codeBodyContents
        let entering = cell.updateBlockViewport(
            fragments: result.fragments,
            viewportInCell: blockViewport(for: cell.layer.frame),
            synchronousContent: syncMap,
            codeBodyContent: codeMap
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
        scale: CGFloat,
        codeStreamDelivery: @MainActor @escaping (Int, CodeBodyLayerContent) -> Void = { _, _ in }
    ) -> (height: CGFloat, fragments: [Fragment], textBitmaps: [Int: CGImage], codeBodyContents: [Int: CodeBodyLayerContent])? {
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
                block.key, descriptor: descriptor, width: block.width, scale: scale, contentHash: block.contentHash,
                formulaCache: environment.formulaCache, fontProvider: environment.mathFontProvider
            ) {
                residentStore.store(sealed.image, size: sealed.size, for: block.key)
                return (sealed.size.height, sealed.image)
            }
            // A code block body that was never hot in this session (e.g. loaded already-sealed
            // from history) never touched HotBlockRasterizerStore above -- it needs the real
            // syntax-highlighted, non-wrapping raster, not the generic freeze() path below (which
            // would rasterize the plain, container-clipped TextDescriptor Flattener produced).
            //
            // `finalize` folds any still-open tail into a final sealed line and spawns at most one
            // off-main parse for whatever isn't colorized yet -- it never runs tree-sitter or a
            // whole-block rasterization inline, so a large block never hitches this scroll-adjacent
            // seal path. The synchronous return may still contain plain (uncolored) tiles; the
            // fully-colorized composite lands later via `onRecolor`, which persists it into
            // `residentStore` under the same identity and pushes it to the live cell, then frees
            // the per-line streaming state -- eviction only happens here immediately when no async
            // colorization is pending.
            if case .body(let chrome) = descriptor.codeBlockRole {
                let bodyKey = codeBodyKey(for: block)
                let fragmentID = block.fragment.id
                let hotCodeStreamStore = environment.hotCodeStreamStore
                let result = hotCodeStreamStore.finalize(
                    bodyKey,
                    rawCode: descriptor.content,
                    font: descriptor.font,
                    theme: themeSnapshot.theme,
                    themeGeneration: themeSnapshot.generation,
                    languageID: LanguageID(fenceInfo: chrome.language),
                    highlightRegistry: environment.highlightRegistry,
                    scale: scale,
                    measure: { [self] d, w in measureTextSync(d, width: w) },
                    eventObserver: environment.codeStreamObserver,
                    onRecolor: { [residentStore] content in
                        // `finalize`'s colorization can land across several bounded chunks (see
                        // `HotCodeStreamStore.recolorChunkSize`) -- evicting or stamping the
                        // stable `codeBodyIdentity` on anything but the LAST chunk would strand
                        // the remaining lines uncolored (a later chunk's `deliverColorRuns` would
                        // find its entry gone and silently drop) and let a still-partially-plain
                        // bitmap be cached as if it were the identity's final, authoritative
                        // raster. `isFullyColorized` is checked fresh on every delivery so only
                        // the chunk that actually completes colorization treats itself as final.
                        let isFinal = hotCodeStreamStore.isFullyColorized(bodyKey)
                        // Only flatten+persist on the delivery that actually finishes colorization.
                        // `composeFullImage` is O(sealed height) -- fine once per block, but calling
                        // it on every intermediate chunked delivery would reintroduce exactly the
                        // O(sealedHeight)-per-turn cost this bead removes from the recolor path.
                        if isFinal, let composed = HotCodeStreamStore.composeFullImage(content, scale: scale) {
                            residentStore.store(composed.image, size: composed.size, for: bodyKey, codeBodyIdentity: codeBodyIdentity)
                        }
                        codeStreamDelivery(fragmentID, content)
                        if isFinal {
                            hotCodeStreamStore.evict([bodyKey])
                        }
                    }
                )
                codeBodyContents[fragmentID] = result.content
                // Runs once per `finalize()` call (fence close), not per line -- an O(sealed
                // height) one-shot flatten here is fine, unlike on the hot append path.
                guard let composed = HotCodeStreamStore.composeFullImage(result.content, scale: scale) else {
                    return (result.height, nil)
                }
                // Only stamp the stable `codeBodyIdentity` when this synchronous result is
                // already fully colorized -- a plain/partially-colored bitmap stored under the
                // same identity as the eventual colorized one would let a scroll-out demote (see
                // `FeedScrollView+Scroll.swift`) freeze it into the cache as a permanently "valid"
                // hit for that identity, even though colorization never finished (the async
                // delivery is dropped once the entry is evicted underneath it).
                residentStore.store(
                    composed.image, size: composed.size, for: bodyKey,
                    codeBodyIdentity: result.needsAsyncColorization ? nil : codeBodyIdentity
                )
                if !result.needsAsyncColorization {
                    hotCodeStreamStore.evict([bodyKey])
                }
                return (result.height, composed.image)
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
                rasterize: { [self] descriptor, layoutWidth, size, s in
                    _testHooks.blockDiffRasterizeCallCount += 1
                    return rasterizeText(
                        descriptor, layoutWidth: layoutWidth, outputSize: size, scale: s,
                        formulaCache: environment.formulaCache, fontProvider: environment.mathFontProvider
                    )
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
        // A code-block body streams instead through HotCodeStreamStore, whose per-line tiles and
        // adaptive defer replace the generic growing-plain-bitmap artifact.
        func measureAndRasterizeHot(_ block: Block) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text(let descriptor) = block.fragment.content else { return nil }
            _testHooks.blockDiffHotAppendCallCount += 1
            if case .body(let chrome) = descriptor.codeBlockRole {
                let fragmentID = block.fragment.id
                let result = environment.hotCodeStreamStore.append(
                    codeBodyKey(for: block),
                    rawCode: descriptor.content,
                    font: descriptor.font,
                    theme: themeSnapshot.theme,
                    themeGeneration: themeSnapshot.generation,
                    languageID: LanguageID(fenceInfo: chrome.language),
                    highlightRegistry: environment.highlightRegistry,
                    scale: scale,
                    measure: { [self] d, w in measureTextSync(d, width: w) },
                    eventObserver: environment.codeStreamObserver,
                    onRecolor: { content in codeStreamDelivery(fragmentID, content) }
                )
                codeBodyContents[fragmentID] = result.content
                // No single bitmap to hand back (chunk list) -- `recordTextResult` reads
                // `codeBodyContents` directly for this fragment's frame width instead.
                return (result.height, nil)
            }
            let result = environment.hotBlockRasterizerStore.append(
                descriptor, width: block.width, scale: scale, contentHash: block.contentHash, for: block.key,
                formulaCache: environment.formulaCache, fontProvider: environment.mathFontProvider
            )
            if let image = result.image {
                residentStore.store(image, size: CGSize(width: block.width, height: result.height), for: block.key)
            }
            return (result.height, result.image)
        }

        // Synchronous measure+raster for a math block, mirroring `measureAndMaybeFreeze`'s role
        // for text -- lets seal commit the formula's height AND pixels in one frame instead of
        // bailing to the async `measureNode` fallback (which would show the old short height for
        // one frame, then jump when the formula lands).
        func measureAndRasterizeMathBlock(_ block: Block)
            -> (height: CGFloat, size: CGSize, bitmap: CGImage?)? {
            guard case .mathBlock = block.fragment.content,
                  case .mathBlock(let d) = newTable.nodes[block.fragment.id] else { return nil }
            let mathLayout = layoutMathBlock(
                rawTeX: d.rawTeX, font: d.font, color: d.color, width: block.width,
                cache: environment.formulaCache,
                allowFormula: d.lifecycle != .hot,
                measure: { [self] desc, w in measureTextSync(desc, width: w) })
            // Must match LayoutEngine's `.mathBlock` contentSize computation exactly (Section 3
            // cross-site consistency) so the sync and async paths can never disagree.
            let size: CGSize
            switch mathLayout {
            case .formula(_, _, let m): size = CGSize(width: max(m.width, block.width), height: m.height)
            case .literal(_, let s):    size = s
            }
            let raster = rasterizeMathBlock(mathLayout, blockWidth: block.width,
                                            scale: scale, fontProvider: environment.mathFontProvider)
            // Persist into the resident tier under `block.key` -- exactly what the text helpers do.
            // Without this the raster lives only in this round's `textBitmaps`; on the next token
            // the now-sealed block is `.reused` (not re-measured), and `buildSyncMap`'s resident
            // lookup finds nothing -- the formula blanks until the whole message stops streaming.
            if let bitmap = raster.image {
                residentStore.store(bitmap, size: size, for: block.key)
            }
            return (size.height, size, raster.image)
        }

        var heights = [CGFloat](repeating: 0, count: newBlocks.count)
        var localFragmentFrames = [CGRect](repeating: .null, count: newBlocks.count)
        var textBitmaps: [Int: CGImage] = [:]
        var codeBodyContents: [Int: CodeBodyLayerContent] = [:]
        var mathSizes: [Int: CGSize] = [:]
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
            //
            // A code body has no single bitmap (its sealed portion is a chunk list) -- its width
            // comes straight from the already-computed chunk content instead.
            let frameWidth: CGFloat
            if case .text(let descriptor) = block.fragment.content, case .body = descriptor.codeBlockRole,
               let content = codeBodyContents[block.fragment.id] {
                frameWidth = content.totalSize.width
            } else {
                frameWidth = result.bitmap.map { CGFloat($0.width) / scale } ?? width
            }
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
                       contentHash: block.contentHash,
                       formulaCache: environment.formulaCache,
                       fontProvider: environment.mathFontProvider
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
            } else if case .mathBlock = block.fragment.content {
                guard let r = measureAndRasterizeMathBlock(block) else { return nil }
                heights[i] = r.height
                localFragmentFrames[i] = CGRect(x: 0, y: 0, width: width, height: r.height)
                textBitmaps[block.fragment.id] = r.bitmap
                mathSizes[block.fragment.id] = r.size
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
            } else if case .mathBlock = block.fragment.content {
                guard let r = measureAndRasterizeMathBlock(block) else { return nil }
                heights[i] = r.height
                localFragmentFrames[i] = CGRect(x: 0, y: 0, width: width, height: r.height)
                textBitmaps[block.fragment.id] = r.bitmap
                mathSizes[block.fragment.id] = r.size
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
            environment.hotCodeStreamStore.evict(removed)
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
                let headerBitmap = cachedHeader ?? rasterizeText(
                    descriptor.headerText, layoutWidth: width, outputSize: headerSize, scale: scale
                )
                let headerWidth = cachedHeaderSize?.width ?? headerBitmap.map { CGFloat($0.width) / scale } ?? headerSize.width
                // Card/background/body frame width is pinned to `width` unconditionally -- a
                // long line (localFrame.width can be the wide raster/chunk-content width) must
                // never expand the card past the feed width. True content width for horizontal
                // scroll comes from `CodeBodyLayerContent.totalSize.width` in RenderCell.
                let bodyFrame = CGRect(x: 0, y: cursor + headerSize.height, width: width, height: localFrame.height)
                let total = CGRect(
                    x: 0, y: cursor, width: width,
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
            // The contract-derived `.table` content always carries `naturalContentSize: .zero`
            // (real size is unknown until rasterization) -- a reused/unchanged table must fall
            // back to the previous fragment's real content instead, or it mounts invisible.
            var content = block.fragment.content
            if case .table = content,
               case .table = previousFragmentByID[block.fragment.id]?.content {
                content = previousFragmentByID[block.fragment.id]!.content
            }
            if case .mathBlock = content {
                // A freshly measured/rasterized math block (this round) carries its real size in
                // `mathSizes` -- use that. Otherwise (unchanged/reused) fall back to the previous
                // fragment's real content, same as `.table` above, since the contract-derived
                // content always carries a placeholder `naturalContentSize`.
                if let s = mathSizes[block.fragment.id],
                   case .mathBlock(let d) = newTable.nodes[block.fragment.id] {
                    content = .mathBlock(MathBlockRasterDescriptor(
                        naturalContentSize: s, layoutHash: d.layoutHash, appearanceHash: d.appearanceHash))
                } else if case .mathBlock = previousFragmentByID[block.fragment.id]?.content {
                    content = previousFragmentByID[block.fragment.id]!.content
                }
            }
            fragments.append(Fragment(
                id: block.fragment.id,
                blockID: block.blockID,
                content: content,
                frame: frame
            ))
            cursor += heights[i]
            if i < trailingIndex { cursor += spacing }
        }
        return (cursor, fragments, textBitmaps, codeBodyContents)
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

        let ordinals = table.leafOrdinals()
        var blocks: [Block] = []
        blocks.reserveCapacity(childIndices.count)
        for nodeIndex in childIndices {
            guard let contract = table.blockRenderContract(
                at: nodeIndex, itemID: itemID, logicalOrdinal: ordinals[nodeIndex] ?? nodeIndex
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
        let ordinals = table.leafOrdinals()
        for nodeIndex in childIndices {
            let ownerBlockID = table.blockID(at: nodeIndex)
            let key = canonicalBlockKey(itemID: itemID, blockID: ownerBlockID, logicalOrdinal: ordinals[nodeIndex] ?? nodeIndex)
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
        return TextMeasurementContext().measure(descriptor, width: width, formulaCache: environment.formulaCache)
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
            scale: scale,
            codeStreamDelivery: { [weak cell] fragmentID, content in
                cell?.applyCodeBodyTile(id: fragmentID, content: content, for: newTable.itemID)
            }
        ) else { return false }

        let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: lastIdx, newHeight: result.height)
        applyContentHeightDelta(delta)
        cell.layer.frame = resolvedFrames[lastIdx]

        var syncMap = buildSyncMap(for: result.fragments, table: newTable, ordinals: newTable.leafOrdinals())
        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
        let codeMap = result.codeBodyContents
        let entering = cell.updateBlockViewport(
            fragments: result.fragments,
            viewportInCell: blockViewport(for: cell.layer.frame),
            synchronousContent: syncMap,
            codeBodyContent: codeMap
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
