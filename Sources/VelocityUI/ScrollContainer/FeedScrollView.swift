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
    public var cellBuilder: (@MainActor (Item) -> any RenderNode)?

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

    /// Called when a user taps a cell. Receives the tapped item and its frame in
    /// scroll-content coordinates.
    public var onTap: (@MainActor (Item, CGRect) -> Void)?

    /// Called when the visible trailing edge nears the end of the item list.
    /// Fired at most once per page; resets when `items.count` grows.
    public var onReachEnd: (@MainActor () async -> Void)?

    /// Opt-in: return a value whose change should invalidate the cached NodeTable for that ID.
    ///
    /// When `nil` (default), every `itemsDidChange` call rebuilds all NodeTables — preserving
    /// existing behavior bit-for-bit. When non-nil, items whose signature equals the cached
    /// value skip `cellBuilder` and `flatten` entirely — eliminating the dominant builder+flatten
    /// cost for unchanged items.
    ///
    /// Contract: if `sig(a) == sig(b)` and `a.id == b.id`, then
    /// `flatten(cellBuilder(a), itemID: a.id)` MUST produce the same NodeTable as
    /// `flatten(cellBuilder(b), itemID: b.id)`. Violations manifest as stale UI, not crashes.
    /// Mirrors SwiftUI's `Equatable` view identity contract. Caller's responsibility.
    public var itemSignature: ((Item) -> AnyHashable)? = nil

    // MARK: - Items

    public var items: [Item] = [] {
        didSet { itemsDidChange(from: oldValue) }
    }

    // MARK: - Dependencies

    private let pipeline: RenderPipeline
    private let workingRange: WorkingRange
    private let differ: RenderDiffer
    private let environment: RenderEnvironment

    /// Read-only view of the composition root.
    /// Exposed for external lifecycle coordination and test double injection.
    public var renderEnvironment: RenderEnvironment { environment }

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
    /// False until the first `layoutSubviews` width transition has been handled. Distinguishes
    /// the initial `0 -> bounds.width` sentinel transition (nothing stale to evict — WorkingRange
    /// and LayoutCache are either empty or hold entries `warmUp` populated at this exact width)
    /// from a genuine width change (rotation/resize), where prior-width entries ARE stale.
    private var hasLaidOutOnce: Bool = false
    private var reachEndFired: Bool = false

    /// Pre-allocated scratch buffer for the recycle loop — avoids a per-frame Array allocation.
    private var _recycleBuffer: [Int] = []

    /// Pre-allocated scratch buffer for `refineKnownFrames` — avoids a fresh Set.union +
    /// Array.sorted allocation on every call while indices remain unrefined.
    private var _refineIndexBuffer: [Int] = []

    /// Indices where the cell was mounted with applyLayout([]) during a WorkingRange miss.
    /// refineKnownFrames delivers real fragments and spawns media fetches when entries arrive.
    private var _pendingFragmentIndices: Set<Int> = []

    private var tableCache: [Item.ID: (sig: AnyHashable, table: NodeTable)] = [:]

    /// Placeholder height for items not yet measured by the pipeline.
    /// Affects the initial contentSize and the scroll distance to the first real layout.
    /// Tunable via init — useful when content is known to be significantly taller or shorter than 300 pt.
    public let estimatedItemHeight: CGFloat

    /// Vertical gap between adjacent cells in scroll-content coordinates.
    public let layoutSpacing: CGFloat

    // MARK: - Debug hooks

    #if canImport(XCTest)
    /// Counts Task spawns from leading-index boundary crossings inside `notifyPipelineIfNeeded`.
    /// Does NOT count the one-shot `onReachEnd` spawn — that fires at most once per page.
    private(set) var _taskSpawnCount: Int = 0

    var _tableCacheCount: Int { tableCache.count }

    /// Returns nil-entry count in WorkingRange for indices in [start, end).
    /// Used by the Phase 1 integration suite to re-validate the Spike 2 ring-buffer
    /// warmup criterion on the real FeedScrollView stack (not just the bare pipeline).
    func _workingRangeMissCount(from start: Int, to end: Int) -> Int {
        guard start < end else { return 0 }
        let clampedEnd = min(end, tables.count)
        guard start < clampedEnd else { return 0 }
        return (start..<clampedEnd).filter { workingRange.entry(at: $0) == nil }.count
    }

    /// Resolved frame for an index, in scroll-content coordinates. nil if the index has never
    /// been laid out. Used by tests to compute a scroll offset that lands a specific index in
    /// the viewport from the item's real (post-measure) frame rather than a hardcoded estimate —
    /// `estimatedItemHeight`-based math silently drifts once WorkingRange refines real heights.
    func _debugResolvedFrame(at index: Int) -> CGRect? {
        index < resolvedFrames.count ? resolvedFrames[index] : nil
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

    /// Count of indices still awaiting fragment delivery via refineKnownFrames — i.e. cells
    /// mounted with `applyLayout([])` during a WorkingRange miss that LayoutCache could not
    /// resolve inline. Should be 0 whenever LayoutCache is warm for all visible indices at
    /// mount time — the inline materialization path bypasses this bookkeeping entirely.
    var _pendingFragmentIndicesCount: Int { _pendingFragmentIndices.count }
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
            imageActor: environment.imageActor,
            prefetchAhead: prefetchAheadCount,
            prefetchBehind: prefetchBehindCount
        )
        self.workingRange = WorkingRange()
        self.differ = RenderDiffer(dimensionCache: environment.dimensionCache)
        super.init(frame: frame)
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
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
            let isFirstLayout = !hasLaidOutOnce
            lastLayoutWidth = w
            hasLaidOutOnce = true
            handleWidthChange(isFirstLayout: isFirstLayout)
        }

        refineKnownFrames()
        let visRange = updateVisibleCells()
        notifyPipelineIfNeeded()
        checkReachEnd(visRange: visRange)
    }

    // MARK: - Items change

    private func itemsDidChange(from oldItems: [Item]) {
        guard let builder = cellBuilder else { return }

        var nextTables: [NodeTable] = []
        nextTables.reserveCapacity(items.count)
        if let signature = itemSignature {
            for item in items {
                let sig = signature(item)
                if let hit = tableCache[item.id], hit.sig == sig {
                    nextTables.append(hit.table)
                } else {
                    let table = flatten(builder(item), itemID: item.id)
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
                nextTables.append(flatten(builder(item), itemID: item.id))
            }
        }
        let nextSnapshot = LayoutSnapshot(tables: nextTables)
        let changeSet = differ.diff(prev: snapshot, next: nextSnapshot)

        guard changeSet.hasChanges else {
            snapshot = nextSnapshot
            tables = nextTables
            return
        }

        // Capture old frames and build (prevIdx, nextIdx) survivors before clobbering them.
        // Covers all items that have a known previous height: .none, .layout, .appearance, .media.
        // Int-keyed — zero AnyHashable boxing.
        let oldFrames = resolvedFrames
        var survivors: [(prevIdx: Int, nextIdx: Int)] = []
        survivors.reserveCapacity(tables.count)
        for e in changeSet.survived      { survivors.append(e) }
        for e in changeSet.layoutChanged { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }
        for e in changeSet.appearanceChanged { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }
        for e in changeSet.mediaChanged  { survivors.append((prevIdx: e.prevIdx, nextIdx: e.nextIdx)) }

        // Recycle cells for removed items — prevIdx is the old index in visibleCells.
        for r in changeSet.removed {
            if let cell = visibleCells.removeValue(forKey: r.prevIdx) {
                returnToPool(cell)
            }
        }

        // Invalidate WorkingRange when any layout-impacting change exists.
        let needsFullInvalidation = !changeSet.layoutChanged.isEmpty ||
                                    !changeSet.removed.isEmpty ||
                                    !changeSet.added.isEmpty
        if needsFullInvalidation {
            workingRange.invalidateAll()
            let pipeline = self.pipeline
            Task { await pipeline.markInvalidated() }
        }

        snapshot = nextSnapshot
        tables = nextTables

        rebuildFrames(oldFrames: oldFrames, survivors: survivors)

        if needsFullInvalidation {
            for (_, cell) in visibleCells {
                cell.layer.removeFromSuperlayer()
                returnToPool(cell)
            }
            visibleCells.removeAll(keepingCapacity: true)
            _pendingFragmentIndices.removeAll(keepingCapacity: true)
        } else {
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
    /// Heights are read from `oldFrames[s.prevIdx]` for each survivor (prevIdx, nextIdx) pair;
    /// indices absent from `survivors` fall back to `estimatedItemHeight`.
    /// Populates `estimatedIndices` for any index using the estimate.
    private func rebuildFrames(oldFrames: [CGRect], survivors: [(prevIdx: Int, nextIdx: Int)]) {
        let w = lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
        let spacing = layoutSpacing
        var knownHeight = [CGFloat?](repeating: nil, count: tables.count)
        for s in survivors where s.prevIdx < oldFrames.count {
            knownHeight[s.nextIdx] = oldFrames[s.prevIdx].height
        }
        resolvedFrames.removeAll(keepingCapacity: true)
        estimatedIndices.removeAll(keepingCapacity: true)
        var cursor: CGFloat = 0
        let last = tables.count - 1
        for i in tables.indices {
            let h: CGFloat
            if let known = knownHeight[i] {
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
                          for: CacheKey(layoutHash: tables[index].layoutHash, width: lastLayoutWidth)
                      ) {
                // WorkingRange still hasn't been populated by the pipeline for this index
                // (e.g. a fast leading-index advance outran notifyPipelineIfNeeded), but
                // LayoutCache already has the entry. Materialize inline — same fallback as
                // updateVisibleCells' WR-miss branch, lower priority per bead since
                // refineKnownFrames normally runs after the pipeline has already committed.
                // Gated on _pendingFragmentIndices (the small, mount-bounded set) — NOT on
                // estimatedIndices, which spans the whole feed and would turn this into an
                // NSCache probe + CacheKeyBox allocation per far-off, never-mounted index.
                workingRange.commit(cacheEntry.layout, cacheEntry.fragments, at: index)
                entry = cacheEntry
            } else {
                continue
            }
            let realHeight = entry.layout.totalFrame.height
            guard realHeight > 0 else { continue }

            let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: index, newHeight: realHeight)
            if delta != 0 { contentSize.height += delta }
            refined.append(index)

            // Deliver real fragments to cells that were mounted during a WorkingRange miss.
            // Check visibleCells first so the set is not mutated when no cell is present.
            if let cell = visibleCells[index], _pendingFragmentIndices.remove(index) != nil {
                cell.layer.frame = resolvedFrames[index]
                let syncMap = buildSyncMap(for: entry.fragments)
                cell.applyLayout(entry.fragments, synchronousContent: syncMap)
                spawnMediaFetches(for: cell, fragments: entry.fragments, itemID: tables[index].itemID,
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

    private func syncContentSize() {
        let height = resolvedFrames.last.map(\.maxY) ?? 0
        let w = lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
        let target = CGSize(width: w, height: height)
        if contentSize != target { contentSize = target }
    }

    // MARK: - Width change

    /// - Parameter isFirstLayout: `true` only for the very first width transition (the
    ///   `0 -> bounds.width` sentinel). On first layout there is no prior width whose entries
    ///   could be stale — `WorkingRange` is empty and any `LayoutCache` entries were populated by
    ///   `AsyncFeed.warmUp` at this SAME width — so the WR/LayoutCache invalidation side effects
    ///   are skipped. `rebuildFrames` + `syncContentSize` still run unconditionally: the frames
    ///   must be (re)computed against the now-known width either way.
    private func handleWidthChange(isFirstLayout: Bool) {
        if !isFirstLayout {
            workingRange.invalidateAll()
            let pipeline = self.pipeline
            Task { await pipeline.markInvalidated() }
            // LayoutCache eviction is async (actor-isolated). Between here and when invalidateAll()
            // completes, a boundary-crossing notifyPipelineIfNeeded will miss on the new-width key —
            // harmless. An in-flight old-width prefetch can still write back entries, but old-width
            // CacheKeys (layoutHash, oldWidth) never collide with new-width keys (layoutHash, newWidth),
            // so no stale data pollutes the new-width lookup path.
            let cache = environment.layoutCache
            Task { await cache.invalidateAll() }
        }
        lastNotifiedLeadingIndex = -1
        rebuildFrames(oldFrames: [], survivors: [])
        syncContentSize()
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

        // Set when a LayoutCache-hit mount below refines resolvedFrames for an index whose
        // real height differs from the estimatedItemHeight placeholder — signals that
        // already-mounted cells at later indices (not touched by this loop, since
        // visibleCells[index] == nil gates re-entry) may need repositioning below.
        var didRefineDuringMount = false

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
                let syncMap = buildSyncMap(for: entry.fragments)
                cell.applyLayout(entry.fragments, synchronousContent: syncMap)
                spawnMediaFetches(for: cell, fragments: entry.fragments, itemID: table.itemID,
                                  syncMap: syncMap)
            } else if let entry = environment.layoutCache.cachedEntry(
                for: CacheKey(layoutHash: table.layoutHash, width: lastLayoutWidth)
            ) {
                // WorkingRange miss, but LayoutCache already has the entry — from a prior
                // pipeline pass at this width, or from AsyncFeed.warmUp() before mount.
                // Materialize inline so this cell gets real fragments in THIS layoutSubviews
                // pass instead of one+ frames of gradient placeholder. Subsequent layoutSubviews
                // calls now hit the WR-hit branch above; refineKnownFrames is bypassed for this
                // index (not added to _pendingFragmentIndices). See WorkingRange.commit's
                // docstring for why a possible double-commit with notifyPipelineIfNeeded's
                // pipeline Task (same index, same LayoutCache-sourced data) is safe.
                workingRange.commit(entry.layout, entry.fragments, at: index)

                // resolvedFrames[index] may still hold the estimatedItemHeight placeholder —
                // this is the first layoutSubviews to see this index, so refineKnownFrames
                // (which runs before this function) had nothing in WorkingRange yet to refine
                // from. Refine here, inline, from the same LayoutCache-sourced layout, so the
                // cell mounts at its real height instead of the stale estimate.
                let realHeight = entry.layout.totalFrame.height
                var mountFrame = frame
                if realHeight > 0 {
                    let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: index, newHeight: realHeight)
                    if delta != 0 {
                        contentSize.height += delta
                        didRefineDuringMount = true
                    }
                    mountFrame = resolvedFrames[index]
                    estimatedIndices.remove(index)
                }

                cell.layer.frame = mountFrame
                let syncMap = buildSyncMap(for: entry.fragments)
                cell.applyLayout(entry.fragments, synchronousContent: syncMap)
                spawnMediaFetches(for: cell, fragments: entry.fragments, itemID: table.itemID,
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

        // A LayoutCache-hit refine above only shifts resolvedFrames for indices AFTER the
        // refined one — any cell already mounted (from a prior pass) at a higher index needs
        // its layer.frame re-synced. Cheap no-op in the common case (didRefineDuringMount is
        // false whenever every visible index either WR-hits or has no LayoutCache entry yet).
        if didRefineDuringMount {
            for (i, cell) in visibleCells {
                guard i < resolvedFrames.count else { continue }
                cell.layer.frame = resolvedFrames[i]
            }
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
        let capturedScale  = max(1, traitCollection.displayScale)  // same guard as spawnMediaFetches

        #if canImport(XCTest)
        _taskSpawnCount += 1
        #endif

        Task { [weak self] in
            guard let self else { return }
            await self.pipeline.onIndexBoundary(
                leading,
                workingRange: self.workingRange,
                tables: capturedTables,
                availableWidth: capturedWidth,
                scale: capturedScale
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

    // MARK: - Tap handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // UIScrollView: bounds.origin = contentOffset, so gesture.location(in:) is already content-space.
        let contentPt = gesture.location(in: self)
        for (index, _) in visibleCells {
            guard index < resolvedFrames.count, index < items.count else { continue }
            if resolvedFrames[index].contains(contentPt) {
                onTap?(items[index], resolvedFrames[index])
                return
            }
        }
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
    ///
    /// `syncMap`: fragments already painted synchronously via applyLayout's synchronousContent
    /// map. These must not receive a second async fetch — they are already in the cache and
    /// the sublayer already has non-nil contents. Passing the map directly avoids an extra
    /// Set allocation per mount; lookup is O(1) via Dictionary subscript.
    private func spawnMediaFetches(
        for cell: RenderCell,
        fragments: [Fragment],
        itemID: AnyHashable,
        syncMap: [Int: CGImage] = [:]
    ) {
        let imageActor = environment.imageActor
        let scale = max(1, traitCollection.displayScale)
        let contentDeliveryObserver = environment.contentDeliveryObserver

        for fragment in fragments {
            guard case .image(let d) = fragment.content, let url = d.url else { continue }
            let fragmentID = fragment.id
            guard syncMap[fragmentID] == nil else { continue }
            let targetSize = fragment.frame.size
            let cornerRadius = d.cornerRadius

            let task = Task { [weak cell] in
                guard let img = await imageActor.image(
                    for: url,
                    targetSize: targetSize,
                    cornerRadius: cornerRadius,
                    scale: scale
                ) else { return }
                // isCancelled guard: primary defence on the fast-scroll path. MediaHandle.cancel()
                // marks the Task cancelled before prepareForReuse rebinds the cell; imageActor.image()
                // may still return a decoded image if the semaphore had already been acquired.
                // This guard catches that window and returns before calling applyContent, keeping
                // RenderCell._privacyGuardFiredCount at zero during fast scroll (Test 5 invariant).
                // applyContent's itemID privacy guard is a defense-in-depth backup for races
                // where cancellation and content delivery coincide after isCancelled is checked.
                guard !Task.isCancelled else { return }
                if let transition = cell?.applyContent(id: fragmentID, image: img, for: itemID) {
                    contentDeliveryObserver?(transition)
                }
            }
            cell.addMediaHandle(MediaHandle(task: task))
        }
    }

    /// Probes the image cache synchronously for each image fragment with a non-nil URL.
    /// Returns a map from fragment.id → CGImage for cache hits only; misses (including
    /// in-flight decodes) are excluded — callers fall back to spawnMediaFetches for those.
    ///
    /// Scale caveat: if preload ran at a different displayScale (e.g. scale 1 in tests,
    /// scale 3 in production), cachedImage returns nil and the fragment is excluded from
    /// the map, silently falling back to the async path. Same constraint as image().
    private func buildSyncMap(for fragments: [Fragment]) -> [Int: CGImage] {
        let imageActor = environment.imageActor
        let scale = max(1, traitCollection.displayScale)
        var map: [Int: CGImage] = [:]
        for fragment in fragments {
            guard case .image(let d) = fragment.content, let url = d.url else { continue }
            if let img = imageActor.cachedImage(for: url, targetSize: fragment.frame.size,
                                                cornerRadius: d.cornerRadius, scale: scale) {
                map[fragment.id] = img
            }
        }
        return map
    }

    // MARK: - Teardown

    /// Cancels all in-flight decode tasks on visible cells and the pipeline's
    /// prefetch task. Safe to call before the view is removed from its parent.
    public func cancelInFlightWork() {
        for cell in visibleCells.values { cell.cancelPendingMedia() }
        let pipeline = self.pipeline
        Task { await pipeline.markInvalidated() }
    }
}
#endif
