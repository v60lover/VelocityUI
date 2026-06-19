// FeedScrollView.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// CALayer-backed vertical feed scroll container.
///
/// THE CONTRACT: `layoutSubviews` → `updateVisibleCells` is fully synchronous.
/// Zero `await`, zero `Task` spawn, zero allocations in steady-state recycling.
/// Pipeline notifications fire only on leading-index boundary crossings.
///
/// Layer ownership: `FeedScrollView.layer` is a plain CALayer; cell layers are
/// direct sublayers. UIScrollView scrolls by adjusting `bounds.origin` — no
/// CAScrollLayer override needed.
@MainActor
public final class FeedScrollView<Item: Identifiable & Sendable>: UIScrollView where Item.ID: Sendable {

    // MARK: - Configuration

    /// Builds the DSL node tree for each item. Must be set before assigning `items`.
    public var cellBuilder: ((Item) -> any RenderNode)?

    /// Number of items to prefetch ahead of the visible leading edge.
    /// Set at init — changing after construction requires a new FeedScrollView
    /// because RenderPipeline is wired with these values at creation time.
    public let prefetchAheadCount: Int

    /// Number of items to keep warmed behind the visible trailing edge.
    /// Set at init — same lifetime constraint as `prefetchAheadCount`.
    public let prefetchBehindCount: Int

    /// How many items before the end of the list `onReachEnd` fires.
    /// Independent of `prefetchBehindCount` — tuning the prefetch window
    /// must not silently move the page-load trigger.
    public let reachEndThreshold: Int

    /// Called when the visible trailing edge nears the end of the item list.
    /// Fired at most once per page; resets when `items.count` grows.
    public var onReachEnd: (@Sendable () async -> Void)?

    // MARK: - Items

    public var items: [Item] = [] {
        didSet { itemsDidChange(from: oldValue) }
    }

    // MARK: - Dependencies

    private let pipeline: RenderPipeline
    private let workingRange: WorkingRange
    private let differ: RenderDiffer
    private let environment: RenderEnvironment

    // MARK: - State

    /// NodeTables in display order. Parallel to `items`.
    private var tables: [NodeTable] = []
    /// Absolute frames in scroll-content coordinates. Parallel to `items`.
    private var resolvedFrames: [CGRect] = []
    /// Previous snapshot passed to RenderDiffer.
    private var snapshot: LayoutSnapshot = LayoutSnapshot(tables: [])

    /// Indices whose heights are estimated (not yet confirmed by WorkingRange).
    /// `refineKnownFrames()` iterates this set; it is empty in steady state.
    private var estimatedIndices: Set<Int> = []

    private var visibleCells: [Int: RenderCell] = [:]
    private var cellPools: [CellKind: [RenderCell]] = [:]

    /// Leading index sent to pipeline on last boundary crossing.
    private var lastNotifiedLeadingIndex: Int = -1

    private var lastLayoutWidth: CGFloat = 0
    private var reachEndFired: Bool = false

    /// Pre-allocated scratch buffer for the recycle loop — avoids a per-frame Array allocation.
    private var _recycleBuffer: [Int] = []

    /// Indices where the cell was mounted with applyLayout([]) during a WorkingRange miss.
    /// refineKnownFrames delivers real fragments and spawns media fetches when entries arrive.
    private var _pendingFragmentIndices: Set<Int> = []

    /// Placeholder height for items not yet measured by the pipeline.
    /// Affects the initial contentSize and the scroll distance to the first real layout.
    /// Tunable via init — useful when content is known to be significantly taller or shorter than 300 pt.
    public let estimatedItemHeight: CGFloat

    /// Vertical gap between adjacent cells in scroll-content coordinates.
    public let layoutSpacing: CGFloat

    // MARK: - Debug hooks

    #if DEBUG
    /// Counts Task spawns from leading-index boundary crossings inside `notifyPipelineIfNeeded`.
    /// Does NOT count the one-shot `onReachEnd` spawn — that fires at most once per page.
    private(set) var _taskSpawnCount: Int = 0
    #endif

    // MARK: - Init

    /// Designated init.
    ///
    /// - Parameters:
    ///   - environment: Composition root. Only `textPool`, `layoutCache`, and
    ///     `dimensionCache` are consumed here; the remaining collaborators
    ///     (`imageActor`, `gifActor`, etc.) are for downstream beads. Taking the
    ///     whole `RenderEnvironment` is an ergonomic convenience — future tightening
    ///     to a per-collaborator init is tracked separately.
    ///   - prefetchAheadCount: Items to prefetch ahead of visible leading edge.
    ///     Wired into `RenderPipeline` at construction time; cannot be changed later.
    ///   - prefetchBehindCount: Items to keep warmed behind visible trailing edge.
    ///     Wired into `RenderPipeline` at construction time; cannot be changed later.
    ///   - reachEndThreshold: How many items before the list end triggers `onReachEnd`.
    ///     Intentionally separate from `prefetchBehindCount` — see `reachEndThreshold`.
    ///   - estimatedItemHeight: Placeholder height for unmeasured items (pt).
    ///     Affects initial contentSize and visual jump when real layouts land.
    ///   - layoutSpacing: Vertical gap between cells (pt).
    public init(
        environment: RenderEnvironment,
        frame: CGRect = .zero,
        prefetchAheadCount: Int = 10,
        prefetchBehindCount: Int = 3,
        reachEndThreshold: Int = 3,
        estimatedItemHeight: CGFloat = 300,
        layoutSpacing: CGFloat = 8
    ) {
        self.environment = environment
        self.prefetchAheadCount = prefetchAheadCount
        self.prefetchBehindCount = prefetchBehindCount
        self.reachEndThreshold = reachEndThreshold
        self.estimatedItemHeight = estimatedItemHeight
        self.layoutSpacing = layoutSpacing
        self.pipeline = RenderPipeline(
            textPool: environment.textPool,
            layoutCache: environment.layoutCache,
            prefetchAhead: prefetchAheadCount,
            prefetchBehind: prefetchBehindCount
        )
        self.workingRange = WorkingRange()
        self.differ = RenderDiffer(dimensionCache: environment.dimensionCache)
        super.init(frame: frame)
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(environment:frame:)") }

    deinit {
        // deinit is not a recycle path — visibleCells are released without passing through
        // returnToPool, so their decode Tasks must be cancelled here to mirror the recycle contract.
        // MainActor.assumeIsolated: FeedScrollView is @MainActor-isolated and can only be
        // deallocated on the main thread, so deinit always runs there. The assumption is safe.
        MainActor.assumeIsolated {
            for cell in visibleCells.values { cell.cancelPendingMedia() }
        }
    }

    // MARK: - Layout

    override public func layoutSubviews() {
        super.layoutSubviews()

        let w = bounds.width
        if w > 0, w != lastLayoutWidth {
            lastLayoutWidth = w
            handleWidthChange()
        }

        refineKnownFrames()
        let visRange = updateVisibleCells()
        notifyPipelineIfNeeded()
        checkReachEnd(visRange: visRange)
    }

    // MARK: - Items change

    private func itemsDidChange(from oldItems: [Item]) {
        guard let builder = cellBuilder else { return }

        let nextTables = items.map { flatten(builder($0), itemID: $0.id) }
        let nextSnapshot = LayoutSnapshot(tables: nextTables)
        let changeSet = differ.diff(prev: snapshot, next: nextSnapshot)

        guard changeSet.hasChanges else {
            snapshot = nextSnapshot
            tables = nextTables
            return
        }

        // Build per-itemID height map from current resolvedFrames before clobbering them.
        var knownHeights: [AnyHashable: CGFloat] = Dictionary(minimumCapacity: tables.count)
        for (i, table) in tables.enumerated() {
            if i < resolvedFrames.count {
                knownHeights[table.itemID] = resolvedFrames[i].height
            }
        }

        // Recycle cells for removed items.
        let removedIDs = Set(changeSet.removed.map(\.itemID))
        let removedIndicesInOld: [Int] = tables.indices.filter { removedIDs.contains(tables[$0].itemID) }
        for idx in removedIndicesInOld {
            if let cell = visibleCells.removeValue(forKey: idx) {
                returnToPool(cell)
            }
        }

        // Invalidate WorkingRange when any layout-impacting change exists.
        let needsFullInvalidation = !changeSet.layoutChanged.isEmpty ||
                                    !changeSet.removed.isEmpty ||
                                    !changeSet.added.isEmpty
        if needsFullInvalidation {
            workingRange.invalidateAll()
        }

        snapshot = nextSnapshot
        tables = nextTables

        rebuildFrames(using: knownHeights)

        if needsFullInvalidation {
            for (_, cell) in visibleCells {
                cell.layer.removeFromSuperlayer()
                returnToPool(cell)
            }
            visibleCells.removeAll(keepingCapacity: true)
            _pendingFragmentIndices.removeAll(keepingCapacity: true)
        } else {
            let newIndexByItemID = Dictionary(
                uniqueKeysWithValues: tables.enumerated().map { ($1.itemID, $0) }
            )
            for (_, next) in changeSet.appearanceChanged {
                guard let idx = newIndexByItemID[next.itemID],
                      let cell = visibleCells[idx],
                      let wrEntry = workingRange.entry(at: idx) else { continue }
                let freshFragments = extractFragments(table: next, layout: wrEntry.layout)
                cell.cancelPendingMedia()
                spawnMediaFetches(for: cell, fragments: freshFragments, itemID: next.itemID)
            }
            for (_, next) in changeSet.mediaChanged {
                guard let idx = newIndexByItemID[next.itemID],
                      let cell = visibleCells[idx],
                      let wrEntry = workingRange.entry(at: idx) else { continue }
                let freshFragments = extractFragments(table: next, layout: wrEntry.layout)
                cell.cancelPendingMedia()
                spawnMediaFetches(for: cell, fragments: freshFragments, itemID: next.itemID)
            }
        }

        // Reset reachEnd gate if item count grew (new page arrived).
        if items.count > oldItems.count {
            reachEndFired = false
        }

        lastNotifiedLeadingIndex = -1

        syncContentSize()
        setNeedsLayout()
    }

    // MARK: - Frame management

    /// Rebuilds `resolvedFrames` in the current `tables` order.
    /// Heights from `knownHeights` when available; falls back to `estimatedItemHeight`.
    /// Populates `estimatedIndices` for any index using the estimate.
    private func rebuildFrames(using knownHeights: [AnyHashable: CGFloat]) {
        let w = lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
        let spacing = layoutSpacing
        resolvedFrames.removeAll(keepingCapacity: true)
        estimatedIndices.removeAll(keepingCapacity: true)
        var cursor: CGFloat = 0
        let last = tables.count - 1
        for (i, table) in tables.enumerated() {
            let h: CGFloat
            if let known = knownHeights[table.itemID] {
                h = known
            } else {
                h = estimatedItemHeight
                estimatedIndices.insert(i)
            }
            resolvedFrames.append(CGRect(x: 0, y: cursor, width: w, height: h))
            cursor += h
            if i < last { cursor += spacing }
        }
    }

    /// Refines heights for indices where WorkingRange has committed real layouts.
    /// Processes indices in ascending order — `refineFrames` shifts subsequent
    /// frames by the delta, so lowest-index-first is required for correct propagation.
    /// O(1) early-exit when `estimatedIndices` is empty (steady state).
    private func refineKnownFrames() {
        guard !estimatedIndices.isEmpty || !_pendingFragmentIndices.isEmpty else { return }

        let sorted = (estimatedIndices.union(_pendingFragmentIndices)).sorted()
        var refined: [Int] = []
        var pendingRepositioned: Set<Int> = []

        for index in sorted {
            guard index < resolvedFrames.count else {
                refined.append(index)
                continue
            }
            guard let entry = workingRange.entry(at: index) else { continue }
            let realHeight = entry.layout.totalFrame.height
            guard realHeight > 0 else { continue }

            let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: index, newHeight: realHeight)
            if delta != 0 { contentSize.height += delta }
            refined.append(index)

            // Deliver real fragments to cells that were mounted during a WorkingRange miss.
            // Check visibleCells first so the set is not mutated when no cell is present.
            if let cell = visibleCells[index], _pendingFragmentIndices.remove(index) != nil {
                cell.layer.frame = resolvedFrames[index]
                cell.applyLayout(entry.fragments)
                spawnMediaFetches(for: cell, fragments: entry.fragments, itemID: tables[index].itemID)
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

    private func syncContentSize() {
        let height = resolvedFrames.last.map(\.maxY) ?? 0
        let w = lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
        let target = CGSize(width: w, height: height)
        if contentSize != target { contentSize = target }
    }

    // MARK: - Width change

    private func handleWidthChange() {
        workingRange.invalidateAll()
        lastNotifiedLeadingIndex = -1
        rebuildFrames(using: [:])
        syncContentSize()
        // LayoutCache eviction is async (actor-isolated). Between here and when invalidateAll()
        // completes, a boundary-crossing notifyPipelineIfNeeded will miss on the new-width key —
        // harmless. An in-flight old-width prefetch can still write back entries, but old-width
        // CacheKeys (layoutHash, oldWidth) never collide with new-width keys (layoutHash, newWidth),
        // so no stale data pollutes the new-width lookup path.
        let cache = environment.layoutCache
        Task { await cache.invalidateAll() }
    }

    // MARK: - Synchronous scroll path

    /// Called from `layoutSubviews`. ZERO await on the scroll path itself.
    /// Media fetch Tasks are spawned at cell-mount time (a state change, not per frame).
    /// Returns the computed visible range so the caller can pass it to `checkReachEnd`.
    @discardableResult
    private func updateVisibleCells() -> Range<Int> {
        guard !resolvedFrames.isEmpty else { return 0..<0 }

        let viewportTop    = contentOffset.y
        let viewportBottom = viewportTop + bounds.height

        let visRange = VerticalLayoutProvider.visibleIndexRange(
            in: resolvedFrames,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom
        )

        // Keep-range for recycle decisions: index-based, allocation-free.
        let keepStart = max(0, visRange.lowerBound - prefetchBehindCount)
        let keepEnd   = min(resolvedFrames.count, visRange.upperBound + prefetchAheadCount)
        let keepRange = keepStart..<keepEnd

        // Collect out-of-range indices into the pre-allocated scratch buffer,
        // then remove. Dictionary.keys is a lazy non-allocating view; _recycleBuffer
        // reuses its backing store after warm-up — no per-frame allocations.
        _recycleBuffer.removeAll(keepingCapacity: true)
        for index in visibleCells.keys where !keepRange.contains(index) {
            _recycleBuffer.append(index)
        }
        for index in _recycleBuffer {
            _pendingFragmentIndices.remove(index)
            if let cell = visibleCells.removeValue(forKey: index) {
                cell.layer.removeFromSuperlayer()
                returnToPool(cell)
            }
        }

        // Mount newly visible cells.
        for index in visRange {
            guard index < resolvedFrames.count, index < tables.count else { continue }
            guard visibleCells[index] == nil else { continue }

            let frame = resolvedFrames[index]
            let table = tables[index]
            let cell  = dequeue(kind: .standard)

            cell.prepareForReuse(for: table.itemID)

            if let entry = workingRange.entry(at: index) {
                cell.layer.frame = frame
                cell.applyLayout(entry.fragments)
                spawnMediaFetches(for: cell, fragments: entry.fragments, itemID: table.itemID)
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

        syncContentSize()
        return visRange
    }

    // MARK: - Pipeline notification

    private func notifyPipelineIfNeeded() {
        guard !tables.isEmpty, !resolvedFrames.isEmpty else { return }

        let visTop    = contentOffset.y
        let visBottom = visTop + bounds.height
        let visRange  = VerticalLayoutProvider.visibleIndexRange(
            in: resolvedFrames, viewportTop: visTop, viewportBottom: visBottom)
        let leading   = visRange.lowerBound

        guard leading != lastNotifiedLeadingIndex else { return }
        lastNotifiedLeadingIndex = leading

        let capturedTables = tables
        let capturedWidth  = bounds.width  // width contract: verbatim, no arithmetic

        #if DEBUG
        _taskSpawnCount += 1
        #endif

        Task { [weak self] in
            guard let self else { return }
            await self.pipeline.onIndexBoundary(
                leading,
                workingRange: self.workingRange,
                tables: capturedTables,
                availableWidth: capturedWidth
            )
            await self.pipeline.waitForCurrentPrefetch()
            self.setNeedsLayout()
        }
    }

    // MARK: - Reach-end detection

    /// Called from `layoutSubviews` after `updateVisibleCells` — NOT from inside
    /// updateVisibleCells itself, so the sync scroll path remains Task-free.
    private func checkReachEnd(visRange: Range<Int>) {
        guard !reachEndFired, let handler = onReachEnd else { return }
        let trailingThreshold = max(0, items.count - max(1, reachEndThreshold))
        guard visRange.upperBound >= trailingThreshold else { return }
        reachEndFired = true
        Task { await handler() }
    }

    // MARK: - Cell pool helpers

    /// Returns a cell from the pool, or allocates a new one.
    ///
    /// Uses `removeValue(forKey:)` to take sole ownership of the array before
    /// calling `removeLast()`. CoW triggers only on the first dequeue from a new pool;
    /// in steady state the pool's backing store is unshared (refcount = 1).
    private func dequeue(kind: CellKind) -> RenderCell {
        guard var pool = cellPools.removeValue(forKey: kind), !pool.isEmpty else {
            return RenderCell(kind: kind)
        }
        let cell = pool.removeLast()
        if !pool.isEmpty { cellPools[kind] = pool }
        return cell
    }

    /// Returns a cell to its kind's pool.
    ///
    /// `removeValue(forKey:)` takes sole ownership so `append` is in-place
    /// when the array has spare capacity (common case after steady-state warm-up).
    private func returnToPool(_ cell: RenderCell) {
        cell.cancelPendingMedia()
        var pool = cellPools.removeValue(forKey: cell.kind) ?? []
        pool.append(cell)
        cellPools[cell.kind] = pool
    }

    // MARK: - Media pipeline

    /// Phase 2 commit: for each image fragment with a non-nil URL, spawn a Task that fetches
    /// and decodes the image then delivers it to the cell. Called at mount time (WR hit) and
    /// from refineKnownFrames when a WR miss is resolved.
    ///
    /// Task body inherits @MainActor isolation (unstructured Task spawned from @MainActor class).
    /// Cell is captured weakly to prevent a Task → cell → mediaHandles → Task retain cycle.
    /// itemID is captured at spawn time and threaded through applyContent; applyContent
    /// rejects callbacks whose captured itemID does not match the cell's currentItemID.
    ///
    /// `max(1, traitCollection.displayScale)` guards against the UITraitCollection returning 0.0
    /// for views not yet attached to a UIWindow (iOS 17+ scene-based traits, unit tests). A zero
    /// scale would produce pixelWidth=pixelHeight=0 in ImageCacheKey and undefined behaviour at
    /// decode; 1× is a safe decode-once floor that the cache supersedes on first real-scale hit.
    private func spawnMediaFetches(
        for cell: RenderCell,
        fragments: [Fragment],
        itemID: AnyHashable
    ) {
        let imageActor = environment.imageActor
        let scale = max(1, traitCollection.displayScale)

        for fragment in fragments {
            guard case .image(let d) = fragment.content, let url = d.url else { continue }
            let fragmentID = fragment.id
            let targetSize = fragment.frame.size
            let cornerRadius = d.cornerRadius

            let task = Task { [weak cell] in
                guard let img = await imageActor.image(
                    for: url,
                    targetSize: targetSize,
                    cornerRadius: cornerRadius,
                    scale: scale
                ) else { return }
                // No Task.isCancelled check here — applyContent's itemID privacy guard
                // is the authoritative defense against stale delivery. Relying on cooperative
                // cancellation alone would leave the invariant untestable: if the Task dies
                // before reaching applyContent, both "guard fired" and "guard never reached"
                // produce the same observable state (opacity == 0).
                cell?.applyContent(id: fragmentID, image: img, for: itemID)
            }
            cell.addMediaHandle(MediaHandle(task: task))
        }
    }
}
#endif
