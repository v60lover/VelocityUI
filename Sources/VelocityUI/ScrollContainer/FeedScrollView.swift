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

    /// VelocityUI-socg C4: does NOT diff/relayout synchronously on assignment. A burst of `items`
    /// assignments within one display frame (e.g. token-by-token streaming) coalesces to exactly
    /// ONE `itemsDidChange` call, drained at the top of the NEXT `layoutSubviews()` — see
    /// `_pendingItemsDiffBase`. This leverages UIKit's own `setNeedsLayout`/`layoutSubviews`
    /// coalescing (multiple `setNeedsLayout()` calls before the next display cycle already
    /// collapse to one `layoutSubviews()`) instead of a hand-rolled CADisplayLink. The established
    /// test pattern `feed.items = X; feed.layoutSubviews()` is unaffected — one assignment plus
    /// one manual `layoutSubviews()` call still yields exactly one `itemsDidChange` call.
    public var items: [Item] = [] {
        didSet {
            if _pendingItemsDiffBase == nil {
                _pendingItemsDiffBase = oldValue
            }
            setNeedsLayout()
        }
    }

    /// The pre-burst `items` value to diff FROM once `layoutSubviews()` drains the coalesced
    /// update — captured only on the FIRST assignment of a burst (subsequent assignments before
    /// the next layout pass must not overwrite it, or the burst would diff against its own
    /// intermediate state instead of the true pre-burst baseline). `nil` in steady state.
    private var _pendingItemsDiffBase: [Item]?

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

    /// `contentOffset.y` observed on the previous `layoutSubviews` pass. Compared against
    /// the current value each pass to derive `scrollDirection` from a real scroll metric.
    private var lastScrollOffsetY: CGFloat = 0

    /// Direction of travel along the scroll axis, updated in `layoutSubviews` from the sign
    /// of the `contentOffset.y` delta. Holds its last value when the offset doesn't change
    /// (at rest, or between two layout passes with no scroll) — avoids flicker at the top/
    /// bottom rubber-band edges. Threaded into `pipeline.onIndexBoundary(direction:)` so
    /// .ahead/.behind prefetch classification tracks actual travel direction. See VelocityUI-im6.
    private var scrollDirection: ScrollDirection = .down

    private var lastLayoutWidth: CGFloat = 0
    /// False until the first `layoutSubviews` width transition has been handled. Distinguishes
    /// the initial `0 -> bounds.width` sentinel transition (nothing stale to evict — WorkingRange
    /// and LayoutCache are either empty or hold entries `warmUp` populated at this exact width)
    /// from a genuine width change (rotation/resize), where prior-width entries ARE stale.
    private var hasLaidOutOnce: Bool = false
    private var reachEndFired: Bool = false

    /// Dynamic Type category threaded into every `flatten()` call (VelocityUI-ezo.2.5).
    /// Initialized from the live trait environment at `init` — mount-time already reflects
    /// the system's real setting rather than defaulting to `.unspecified` (no scaling) until
    /// the first `didChangeNotification` fires. Updated only by `handleContentSizeCategoryChange`.
    private var contentSizeCategory: VContentSizeCategory = .unspecified
    private let notificationCenter: NotificationCenter
    private var contentSizeCategoryObserver: NSObjectProtocol?

    /// Pre-allocated scratch buffer for the recycle loop — avoids a per-frame Array allocation.
    private var _recycleBuffer: [Int] = []

    /// Largest `keepRange.count` seen so far — only the driver knows the real working-range
    /// shape (prefetchBehind + visible + prefetchAhead), and only after first layout, so
    /// `FrozenBitmapStore`'s byte budget (fixed at the 16 MB default at construction, before
    /// this feed existed) is resized from this once it grows. Tracked monotonically-up so a
    /// transient shrink (e.g. rotation narrowing the viewport) never shrinks the live budget
    /// mid-scroll — a shrink would thrash-evict blocks still inside the window.
    private var _frozenBudgetWindowCount: Int = 0

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

    /// Mirrors `scrollDirection` as it's set in `layoutSubviews`. Test-only observability for
    /// VelocityUI-im6 — lets tests assert the signal flips from a real `contentOffset.y` delta
    /// without needing to round-trip through `RenderPipeline`/`ImageActor`.
    private(set) var _lastScrollDirection: ScrollDirection = .down

    /// Branch counters for `AsyncFeed.itemsDiffer`'s buffer-identity fast path (case b, O(1))
    /// vs the `Equatable` deep-comparison fallback (case c, O(n)). Incremented by `itemsDiffer`
    /// itself (a different file in the same module — not `private(set)`, so it can assign here).
    /// Used to verify the fast path is taken for structurally-identical, CoW-preserved items
    /// arrays across repeated `updateUIView` calls, and never falls through to deep equality.
    var _itemsDiffer_bufferHitCount: Int = 0
    var _itemsDiffer_deepEqualCount: Int = 0

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

    /// See `RenderCell._debugPaintedBitmaps`'s doc. Empty dict if the index has no mounted cell.
    func _debugPaintedBitmaps(at index: Int) -> [Int: CGImage] {
        visibleCells[index]?._debugPaintedBitmaps ?? [:]
    }

    /// Re-derives fragments by walking `workingRange.entry(at: index)`'s `layout` through
    /// `extractFragments`, using the item's CURRENT `NodeTable`. `nil` if there's no committed
    /// WorkingRange entry or the index is out of range. VelocityUI-socg C4: the fast path patches
    /// WorkingRange with a SYNTHETIC `ResolvedLayout` (built from block-diff's resolved fragments,
    /// not a real `measureNode` tree) — this hook lets a test confirm that synthetic layout
    /// round-trips correctly through the SAME code path a later appearanceChanged/mediaChanged
    /// classification on this item would use (FeedScrollView.swift's `extractFragments(table:
    /// layout:)` call sites), rather than only trusting it by inspection.
    func _debugExtractFragmentsFromWorkingRange(at index: Int) -> [Fragment]? {
        guard let entry = workingRange.entry(at: index), index < tables.count else { return nil }
        return extractFragments(table: tables[index], layout: entry.layout)
    }

    /// Count of indices still awaiting fragment delivery via refineKnownFrames — i.e. cells
    /// mounted with `applyLayout([])` during a WorkingRange miss that LayoutCache could not
    /// resolve inline. Should be 0 whenever LayoutCache is warm for all visible indices at
    /// mount time — the inline materialization path bypasses this bookkeeping entirely.
    var _pendingFragmentIndicesCount: Int { _pendingFragmentIndices.count }

    /// Counts `dequeue(kind:)` calls that fell through to `RenderCell(kind:)` (a pool miss —
    /// the sole `RenderCell` alloc site). Used by the VelocityUI-ksh regression test to verify
    /// the cell pool CONVERGES after warm-up (miss count stops growing once the working-range
    /// window has been filled once) instead of missing on ~90% of dequeues every frame.
    private(set) var _dequeueAllocCount: Int = 0

    /// Counts `dequeue(kind:)` calls served from `cellPools` (a pool hit — no allocation).
    var _dequeueHitCount: Int = 0

    /// Counts `returnToPool(_:)` calls — every time a cell's shell is handed back to
    /// `cellPools` rather than kept bound in `visibleCells`. VelocityUI-socg C2: a same-id
    /// streaming update must NOT increment this (the `.inPlace` branch keeps the shell); a
    /// different-id item replacement, or genuine scroll-driven eviction, still does.
    private(set) var _returnToPoolCount: Int = 0

    /// VelocityUI-socg C3: counts calls into the in-place block-diff's text measure/rasterize
    /// primitives (`measureTextSync` / the `rasterize` closure `applyInPlaceBlockDiff` wires
    /// into `freeze(_:)`). The anti-jank invariant under test is that these counts per streaming
    /// update stay FLAT (bounded by "the hot tail, plus at most one just-finalized block") as a
    /// message's block count grows — never O(message length).
    private(set) var _blockDiffMeasureCallCount: Int = 0
    private(set) var _blockDiffRasterizeCallCount: Int = 0
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
    ///   - notificationCenter: Source of `UIContentSizeCategory.didChangeNotification` for
    ///     Dynamic Type invalidation (VelocityUI-ezo.2.5). Default `.default` — a system-API
    ///     singleton allowed only as an injected default per CLAUDE.md's no-singletons rule.
    ///     Tests inject a private instance and post directly to it for deterministic coverage.
    public init(
        environment: RenderEnvironment,
        frame: CGRect = .zero,
        prefetchAheadCount: Int = 10,
        prefetchBehindCount: Int = 3,
        reachEndThreshold: Int = 3,
        estimatedItemHeight: CGFloat = 300,
        layoutSpacing: CGFloat = 8,
        notificationCenter: NotificationCenter = .default
    ) {
        self.environment = environment
        self.prefetchAheadCount = prefetchAheadCount
        self.prefetchBehindCount = prefetchBehindCount
        self.reachEndThreshold = reachEndThreshold
        self.estimatedItemHeight = estimatedItemHeight
        self.layoutSpacing = layoutSpacing
        self.notificationCenter = notificationCenter
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

        contentSizeCategory = VContentSizeCategory(traitCollection.preferredContentSizeCategory)
        // queue: nil — the OS always posts this notification on main, and synchronous delivery
        // on the posting thread keeps this consistent with "scroll path never awaits" (no async
        // settle window needed in tests, which post directly to an injected NotificationCenter).
        contentSizeCategoryObserver = notificationCenter.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            // Extracted here (nonisolated) rather than inside the MainActor.assumeIsolated
            // closure below: Swift 6 region isolation rejects sending the non-Sendable-checked
            // `Notification` itself across the hop. `UIContentSizeCategory?` is a plain Sendable
            // value, so extracting it first sidesteps the region-isolation error entirely.
            let uiCategory = note.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? UIContentSizeCategory
            guard let self else { return }
            MainActor.assumeIsolated { self.handleContentSizeCategoryChange(uiCategory: uiCategory) }
        }
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
            if let contentSizeCategoryObserver {
                notificationCenter.removeObserver(contentSizeCategoryObserver)
            }
        }
    }

    // MARK: - Dynamic Type

    /// Reads the new category from the notification's payload rather than unconditionally
    /// re-reading `traitCollection.preferredContentSizeCategory` — the OS always includes
    /// `UIContentSizeCategory.newValueUserInfoKey`, and reading it directly is what makes this
    /// testable without needing a real trait-collection override on a bare, windowless view
    /// (falls back to the live trait only if a caller posts a notification without it).
    private func handleContentSizeCategoryChange(uiCategory: UIContentSizeCategory?) {
        let newCategory = VContentSizeCategory(uiCategory ?? traitCollection.preferredContentSizeCategory)
        guard newCategory != contentSizeCategory else { return }
        contentSizeCategory = newCategory
        // itemSignature's cached tables were flattened at the OLD category — their signature
        // doesn't encode it, so a signature hit here would silently serve stale (wrong-scale)
        // text. Clearing forces every item back through flatten() with the new category.
        tableCache.removeAll(keepingCapacity: true)
        itemsDidChange(from: items)
    }

    /// `init(frame:)` builds this view before UIKit inserts it under a window/scene, so the
    /// `traitCollection` read at construction time (line above, in `init`) reflects the process
    /// default, not the live system setting — traits only propagate once a view is attached to
    /// its eventual trait environment. A user who launches with an accessibility text size
    /// enabled would otherwise get `.unspecified` at cold-launch mount and see unscaled text
    /// until the next `didChangeNotification`, which the OS posts only on a live change, never
    /// on mount. Re-deriving the category here, once the view is actually attached, catches the
    /// real category at the first reliable read point. Routed through the existing
    /// `handleContentSizeCategoryChange` so this stays a no-op re-parent when the category
    /// hasn't changed (e.g. moving between views in the same window).
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        handleContentSizeCategoryChange(uiCategory: traitCollection.preferredContentSizeCategory)
    }

    // MARK: - Layout

    override public func layoutSubviews() {
        super.layoutSubviews()

        // VelocityUI-socg C4: drain any coalesced `items` burst FIRST — `refineKnownFrames`/
        // `updateVisibleCells` below read `tables`/`resolvedFrames`/`estimatedIndices`, which
        // only `itemsDidChange` updates. `itemsDidChange` clears `_pendingItemsDiffBase` itself
        // (as its very first action) so this can't double-drain even if something else already
        // called it directly this pass (e.g. `handleContentSizeCategoryChange`).
        if let base = _pendingItemsDiffBase {
            itemsDidChange(from: base)
        }

        let offsetY = contentOffset.y
        if offsetY != lastScrollOffsetY {
            scrollDirection = offsetY > lastScrollOffsetY ? .down : .up
            lastScrollOffsetY = offsetY
            #if canImport(XCTest)
            _lastScrollDirection = scrollDirection
            #endif
        }

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
        // Cleared unconditionally, regardless of call site (the `items` didSet's deferred drain
        // in `layoutSubviews`, or a direct call like `handleContentSizeCategoryChange`'s) — any
        // call fully resyncs `snapshot`/`tables` to the CURRENT `items`, so a pending marker from
        // before this call is always stale afterward and must not trigger a redundant re-drain.
        _pendingItemsDiffBase = nil
        guard let builder = cellBuilder else { return }

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

        // VelocityUI-socg C4: a pure streaming update (every layoutChanged entry is a same-
        // position, currently-visible survivor — no add/remove) is a candidate to SKIP the
        // full-window invalidation below and instead patch WorkingRange directly for just the
        // block-diff-resolved indices (see the post-loop commit below). Eligibility only —
        // whether we actually take the fast path depends on every layoutChanged entry's block
        // diff succeeding, decided after the loop runs. Excluding off-screen layoutChanged
        // entries here matters: applyInPlaceBlockDiff is only ATTEMPTED for visible cells inside
        // the loop below, so an off-screen layoutChanged item would never get a WorkingRange
        // patch under the fast path and would be stranded stale forever.
        let canDeferInvalidation = needsFullInvalidation
            && changeSet.removed.isEmpty && changeSet.added.isEmpty
            && !changeSet.layoutChanged.isEmpty
            && changeSet.layoutChanged.allSatisfy { $0.prevIdx == $0.nextIdx && visibleCells[$0.prevIdx] != nil }

        // VelocityUI-socg C3: capture the per-block diff inputs for every layout-changed
        // survivor BEFORE workingRange.invalidateAll() below wipes the ring buffer — the OLD
        // fragments (with their real, previously-measured per-block heights) are only readable
        // from WorkingRange right now; once invalidated there is no way to recover them short of
        // a full re-measure, which is exactly the O(item length) cost this diff exists to avoid.
        // `changeSet.layoutChanged` already carries the (prev, next) NodeTable pair directly —
        // no need to re-derive it from `tables`/`nextTables` before/after the reassignment below.
        // Reading WorkingRange here is safe under `canDeferInvalidation` too — that path only
        // SKIPS invalidation, it never reorders this capture relative to it.
        var blockDiffInputs: [Int: (previousTable: NodeTable, newTable: NodeTable, previousFragments: [Fragment])] = [:]
        if needsFullInvalidation {
            for e in changeSet.layoutChanged {
                guard let wrEntry = workingRange.entry(at: e.prevIdx) else { continue }
                blockDiffInputs[e.prevIdx] = (e.prev, e.next, wrEntry.fragments)
            }

            if !canDeferInvalidation {
                workingRange.invalidateAll()
                let pipeline = self.pipeline
                Task { await pipeline.markInvalidated() }
            }
        }

        snapshot = nextSnapshot
        tables = nextTables

        rebuildFrames(oldFrames: oldFrames, survivors: survivors)

        // Set only by the fully-resolved C4 fast path below (every layoutChanged entry patched
        // WorkingRange directly, no invalidation) — gates the `lastNotifiedLeadingIndex` reset
        // near the end of this method.
        var tookInPlaceFastPath = false

        if needsFullInvalidation {
            // reuseDecision(oldID:newID:) (Pipeline/ReuseDecision.swift, VelocityUI-0wi) gates
            // recycling here instead of the old unconditional pool-return of every visible cell.
            // `survivors` (built above) is exactly the set of (prevIdx, nextIdx) pairs the differ
            // already matched by item id — every prevIdx present in `survivorByPrevIdx` is bound
            // to the SAME item identity as its nextIdx slot (RenderDiffer.diff keys survived/
            // layoutChanged/appearanceChanged/mediaChanged off itemID). Calling reuseDecision
            // explicitly, rather than silently trusting that invariant, makes the decision rule
            // the one source of truth for "keep the shell vs. pool it" and gives a real branch
            // to unit-test (VelocityUI-socg C2).
            var survivorByPrevIdx: [Int: Int] = [:]
            survivorByPrevIdx.reserveCapacity(survivors.count)
            for s in survivors { survivorByPrevIdx[s.prevIdx] = s.nextIdx }

            var keptCells: [Int: RenderCell] = [:]
            keptCells.reserveCapacity(visibleCells.count)
            // C3: indices the block-diff path below already resolved synchronously (correct
            // height + repositioned fragments) — excluded from the `_pendingFragmentIndices`
            // re-enroll so refineKnownFrames doesn't redundantly redo the same work through the
            // async pipeline once WorkingRange recommits.
            var blockDiffResolvedIndices: Set<Int> = []
            // C4: WorkingRange patches for the fast path — populated only when
            // `canDeferInvalidation`, applied after the loop IFF every layoutChanged entry
            // resolved (see the post-loop decision below). A synthetic ResolvedLayout mirroring
            // exactly what `extractFragments` would derive: root nodeIndex 0 spanning the item
            // (flatBlocks guarantees an unframed root vstack — see its doc), one child per
            // resolved fragment at nodeIndex == fragment.id and totalFrame == fragment.frame
            // (already item-local coordinates, same space `extractFragments` produces). This
            // keeps a LATER appearanceChanged/mediaChanged classification on the same item
            // (which reads `wrEntry.layout` via `extractFragments`, not `wrEntry.fragments`)
            // correct instead of walking a bogus/empty tree.
            var blockDiffWorkingRangeCommits: [Int: (layout: ResolvedLayout, fragments: [Fragment])] = [:]
            let width = lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
            let scale = max(1, traitCollection.displayScale)
            for (prevIdx, cell) in visibleCells {
                if let nextIdx = survivorByPrevIdx[prevIdx], nextIdx < tables.count,
                   reuseDecision(oldID: cell.currentItemID, newID: tables[nextIdx].itemID) == .inPlace {
                    // Detach (do not reposition here): survivor indices can shift relative to
                    // items still to be freshly mounted this pass (e.g. a prepend moves this
                    // cell from index 0 to 1 while a brand-new item takes index 0) — reattaching
                    // now would leave it z-ordered ahead of a not-yet-mounted lower index.
                    // `updateVisibleCells`' mount loop re-attaches it in the same ascending
                    // visible-index order a fresh mount uses, so z-order still matches display
                    // order without a pool round-trip.
                    cell.layer.removeFromSuperlayer()
                    keptCells[nextIdx] = cell

                    // C3: per-block diff (diff(previous:new:) + freeze application) — unchanged
                    // blocks reused verbatim from FrozenBitmapStore (zero re-measure/rasterize),
                    // only the hot tail / newly-appended blocks touched. `applyInPlaceBlockDiff`
                    // returns nil whenever it cannot GUARANTEE correct content cheaply (non-flat
                    // item shape, no previous-fragment baseline, or a changed image/geometry
                    // block Block-level diff has no way to remeasure) — those fall through to
                    // the pre-existing `_pendingFragmentIndices` full-refresh path below exactly
                    // as C2 left it, rather than risk painting wrong/stale content.
                    if let inputs = blockDiffInputs[prevIdx], nextIdx < items.count,
                       let result = applyInPlaceBlockDiff(
                           previousTable: inputs.previousTable,
                           previousFragments: inputs.previousFragments,
                           newTable: inputs.newTable,
                           itemID: items[nextIdx].id,
                           width: width,
                           scale: scale
                       ) {
                        let delta = VerticalLayoutProvider.refineFrames(&resolvedFrames, at: nextIdx, newHeight: result.height)
                        if delta != 0 { contentSize.height += delta }
                        estimatedIndices.remove(nextIdx)
                        cell.layer.frame = resolvedFrames[nextIdx]
                        // Merge image cache hits with the block-diff's freshly-resolved text
                        // bitmaps (VelocityUI-socg C3 activation — this is the missing consumer
                        // that makes FrozenBitmapStore's cached bitmaps actually paint). Fragment
                        // ids never collide across content kinds within one item's NodeTable, so
                        // a plain overwrite-merge is safe — the two maps are disjoint by key.
                        var syncMap = buildSyncMap(for: result.fragments)
                        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
                        cell.applyLayout(result.fragments, synchronousContent: syncMap)
                        spawnMediaFetches(for: cell, fragments: result.fragments, itemID: inputs.newTable.itemID,
                                          syncMap: syncMap)
                        blockDiffResolvedIndices.insert(nextIdx)
                        if canDeferInvalidation {
                            let syntheticLayout = ResolvedLayout(
                                totalFrame: CGRect(x: 0, y: 0, width: width, height: result.height),
                                children: result.fragments.map { ResolvedLayout(totalFrame: $0.frame, nodeIndex: $0.id) },
                                nodeIndex: 0
                            )
                            blockDiffWorkingRangeCommits[nextIdx] = (syntheticLayout, result.fragments)
                        }
                    }
                } else {
                    cell.layer.removeFromSuperlayer()
                    returnToPool(cell)
                }
            }
            visibleCells = keptCells

            // C4: resolve the deferred invalidation decision. `canDeferInvalidation` only
            // established ELIGIBILITY (no add/remove, every layoutChanged entry visible at a
            // stable position) — whether every one of them actually resolved via block-diff is
            // only known now. All-resolved: patch WorkingRange directly for just those indices,
            // skipping the full-window invalidate + pipeline re-measure entirely (VelocityUI-socg
            // C4's "suppress the redundant background re-measure" — a streaming token update no
            // longer forces the ENTIRE prefetch window to re-measure through RenderPipeline).
            // Partial failure: fall back to EXACTLY today's behavior (full invalidate + markInvalidated),
            // just decided here instead of upfront — safe because nothing between the original
            // call site and here reads `workingRange` (verified: `applyInPlaceBlockDiff` only
            // consumes `blockDiffInputs`, captured before either branch).
            if canDeferInvalidation {
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
            // Re-enroll every kept .inPlace index so refineKnownFrames refreshes its content
            // once the pipeline recommits WorkingRange — must run AFTER removeAll above, or
            // the clear would wipe these entries right back out. Without this, a same-id
            // survivor freezes on its pre-change content until it scrolls out of keep-range
            // and re-mounts (see VelocityUI-socg review finding). Indices the C3 block-diff
            // path already resolved above are excluded (see `blockDiffResolvedIndices`'s doc).
            _pendingFragmentIndices.formUnion(keptCells.keys.filter { !blockDiffResolvedIndices.contains($0) })
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

        // On the fully-resolved fast path, nothing the pipeline needs to re-measure changed —
        // WorkingRange was patched directly (not invalidated), neighbors are untouched, and the
        // leading index is whatever it already was. Forcing a re-notify here would only spawn a
        // `notifyPipelineIfNeeded` Task that immediately early-returns inside `onIndexBoundary`
        // (the pipeline's own last-notified index was never reset either, since `markInvalidated()`
        // never ran on this path) — one wasted Task + actor hop per streaming token for nothing.
        // Leaving the previous value in place is still correct if the leading index genuinely
        // shifted (e.g. growth pushed the visible range): `notifyPipelineIfNeeded` compares
        // against it and notifies normally in that case.
        if !tookInPlaceFastPath {
            lastNotifiedLeadingIndex = -1
        }

        syncContentSize()
        setNeedsLayout()
    }

    // MARK: - VelocityUI-socg C3: in-place per-block diff

    /// Attempts the C3 per-block diff for one `.inPlace` survivor: builds the previous/new
    /// `[Block]` lists from each side's `NodeTable` (only for the flat shape `flatBlocks(for:
    /// width:)` recognizes), diffs them with `diff(previous:new:)`, and for every block that
    /// changed, re-measures — freezing it into `environment.frozenBitmapStore` when it is TEXT
    /// and has finished growing (see `flatBlocks`'s and this method's inline docs). Returns the
    /// item's new total height, its full repositioned `[Fragment]` list (so any image blocks
    /// after a resized text block still land at the right y-offset), and a `fragment.id ->
    /// CGImage` map of every text block's current bitmap (unchanged blocks' verbatim
    /// `FrozenBitmapStore` hit, freshly re-rasterized hot-tail/appended/edited blocks alike) —
    /// the caller merges this into `synchronousContent` so `RenderCell.applyLayout` paints real
    /// pixels instead of leaving text blank (VelocityUI-socg C3 activation: this is what makes
    /// the store's cached bitmaps an actual DISPLAY consumer, not just a computed-and-discarded
    /// cache). `nil` when this update cannot be optimized SAFELY — the caller falls back to the
    /// pre-existing `_pendingFragmentIndices` full-refresh path rather than risk stale/wrong content.
    ///
    /// `previousFragments` must be the REAL fragments `extractFragments` produced for this item
    /// the last time it was measured (captured from `WorkingRange` before `invalidateAll()` —
    /// see the `itemsDidChange` call site) — they are the only source of the OLD content's real
    /// per-block heights, since `flatBlocks`' synthetic `Fragment`s carry no height of their own.
    ///
    /// `itemID` is `Item.ID` (this feed's real, `Hashable & Sendable` id type) rather than
    /// `NodeTable.itemID` (`AnyHashable`) — `BlockKey`'s generic init requires `Hashable &
    /// Sendable`, and `AnyHashable` does not conform to `Sendable` in this SDK (see
    /// `BlockKey`'s own doc comment). `.inPlace` guarantees `previousTable`/`newTable` share the
    /// same identity, so one `itemID` covers both `flatBlocks` calls below.
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
              previousBlocks.count == previousFragments.count,
              !newBlocks.isEmpty
        else { return nil }

        let d = diff(previous: previousBlocks, new: newBlocks)
        let unchangedSet = Set(d.unchanged)
        let overlap = min(previousBlocks.count, newBlocks.count)
        let trailingIndex = newBlocks.count - 1
        let store = environment.frozenBitmapStore

        // Measures (+ rasterizes, + freezes into `store` when `persist`) one TEXT block via the
        // phase-A `freeze(_:)` primitive. `nil` return means `block` is not text — the caller
        // must bail the whole optimization (image/geometry reuse lives in ImageActor's decode
        // cache, never here — see FreezeState.swift's doc). A fresh, function-scoped `cache`
        // dict is passed on every call so `freeze(_:)` always recomputes here — the PERSISTENT
        // cache is `store`, consulted separately (below) for the genuinely-unchanged case, so
        // this always represents real new work, never a stale hit.
        func measureAndMaybeFreeze(_ block: Block, persist: Bool) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text = block.fragment.content else { return nil }
            var localCache: [BlockKey: FreezeState] = [:]
            // `freeze(_:)` always calls `measure` before attempting `rasterize`, but on a
            // rasterize failure (degenerate size — e.g. a still-empty just-appended block) it
            // returns bare `.hot` with no associated size. Capture the measured size as a side
            // effect of the injected `measure` closure so the `.hot` fallback below can reuse it
            // instead of re-measuring — a second `measureTextSync` call there would double-count
            // this block's cost for the SAME update (the flat-per-update-cost invariant this
            // whole path exists for).
            var measuredSize: CGSize?
            let state = freeze(
                block, scale: scale, cache: &localCache,
                measure: { [self] descriptor, w in
                    let s = measureTextSync(descriptor, width: w)
                    measuredSize = s
                    return s
                },
                rasterize: { [self] descriptor, size, s in
                    #if canImport(XCTest)
                    _blockDiffRasterizeCallCount += 1
                    #endif
                    return rasterizeText(descriptor, size: size, scale: s)
                }
            )
            switch state {
            case .frozen(let size, let bitmap):
                if persist {
                    let pixelW = size.width * scale
                    let pixelH = size.height * scale
                    let cost = Int((pixelW * pixelH * 4).rounded(.up))
                    store.store(bitmap, size: size, cost: cost, for: block.key)
                }
                return (size.height, bitmap)
            case .hot:
                // Rasterization failed on a degenerate size — freeze() intentionally returns
                // uncached .hot so a later call can retry. `measuredSize` was still captured
                // above (freeze() measures unconditionally), so this needs no extra work.
                // No bitmap: RenderCell paints blank rather than a stale/wrong image for this
                // fragment id until a later round rasterizes successfully.
                return (measuredSize?.height ?? 0, nil)
            }
        }

        var heights = [CGFloat](repeating: 0, count: newBlocks.count)
        var textBitmaps: [Int: CGImage] = [:]
        for i in 0..<overlap {
            let block = newBlocks[i]
            if unchangedSet.contains(i) {
                if case .text = block.fragment.content {
                    if let size = store.size(for: block.key) {
                        // bump LRU recency — verbatim reuse — and thread the SAME CGImage
                        // instance through so the caller paints it without a re-rasterize.
                        textBitmaps[block.fragment.id] = store.bitmap(for: block.key)
                        heights[i] = size.height
                    } else {
                        // Self-heal: logically unchanged per diff(), but the store has no entry
                        // yet (first pass through C3 for this block, or it was LRU/pressure-
                        // evicted) — recompute once and (re-)freeze it, same as a finalized tail.
                        guard let result = measureAndMaybeFreeze(block, persist: true) else { return nil }
                        heights[i] = result.height
                        textBitmaps[block.fragment.id] = result.bitmap
                    }
                } else {
                    // Non-text, unchanged: trust the previous real fragment height directly —
                    // never frozen/measured here (image/geometry reuse lives in ImageActor).
                    heights[i] = previousFragments[i].frame.height
                }
                continue
            }
            // Not in `unchanged`: either the trailing block grew (`d.hotTail == i`), or — per
            // `diff(previous:new:)`'s doc — an EARLY block changed, which the streaming model
            // does not expect and `diff` intentionally leaves unclassified (VelocityUI-socg
            // design note #4, "edit-invalidation"). Both cases need the same treatment here:
            // this block's content changed, so re-measure it and, if it has closed out (it is
            // not the new trailing block), freeze + store the result — overwriting any stale
            // entry `store` already held for this key (`store(...)` updates in place; see its
            // doc — no separate evict-then-store two-step needed for correctness).
            let persist = i != trailingIndex
            guard let result = measureAndMaybeFreeze(block, persist: persist) else { return nil }
            heights[i] = result.height
            textBitmaps[block.fragment.id] = result.bitmap
        }
        for i in overlap..<newBlocks.count {
            let persist = i != trailingIndex
            guard let result = measureAndMaybeFreeze(newBlocks[i], persist: persist) else { return nil }
            heights[i] = result.height
            textBitmaps[newBlocks[i].fragment.id] = result.bitmap
        }

        var cursor: CGFloat = 0
        var fragments: [Fragment] = []
        fragments.reserveCapacity(newBlocks.count)
        for (i, block) in newBlocks.enumerated() {
            let frame = CGRect(x: 0, y: cursor, width: width, height: heights[i])
            fragments.append(Fragment(id: block.fragment.id, content: block.fragment.content, frame: frame))
            cursor += heights[i]
            if i < trailingIndex { cursor += spacing }
        }
        return (cursor, fragments, textBitmaps)
    }

    /// Recognizes the one item shape this bind-site diff optimizes: a root `.vstack` whose
    /// DIRECT children are all leaves (text/image/spacer/hosting/gif/video/customLayer) — no
    /// nesting, no hstack/zstack — exactly the "VStack of streaming message blocks" shape a chat
    /// message produces. Returns `nil` for any other shape (nested containers, a non-vstack
    /// root, a root with `.frame()` applied to it) so the caller falls back to the pre-existing
    /// full-refresh path instead of a partial, possibly-wrong optimization for a tree this
    /// block-level diff was not designed to model — flagged in the C3 report as the scoped-down
    /// "minimal reasonable mapping" decision (see VelocityUI-socg C3 design notes).
    ///
    /// Blocks are positioned 0-height placeholders at `width` — real per-block height is filled
    /// in by the caller (`applyInPlaceBlockDiff`) from measurement/the frozen-bitmap store, never
    /// read from the `Fragment`s this returns.
    ///
    /// `itemID` is the caller's real `Item.ID`, NOT `table.itemID` (`AnyHashable`) — see
    /// `applyInPlaceBlockDiff`'s doc for why `BlockKey` needs a genuinely `Sendable` id.
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
            let content: FragmentContent
            switch table.nodes[nodeIndex] {
            case .text(let d): content = .text(d)
            case .image(let d): content = .image(d)
            case .spacer, .hosting, .gif, .video, .customLayer: content = .geometry
            case .vstack, .hstack, .zstack: return nil  // nested container — not flat, bail
            }
            let frame = CGRect(x: 0, y: 0, width: width, height: 0)
            let fragment = Fragment(id: nodeIndex, content: content, frame: frame)
            let key = BlockKey(itemID: itemID, index: position)
            blocks.append(Block(key: key, fragment: fragment, layout: ResolvedLayout(totalFrame: frame)))
        }
        return (blocks, vstackDescriptor.spacing)
    }

    /// Emits just the BlockKeys for the flat-vstack-of-leaves shape `flatBlocks` recognizes,
    /// WITHOUT building any `Block`/`Fragment`/`ResolvedLayout` or computing `contentHash` — the
    /// scroll-path admit/evict window bookkeeping needs only `(itemID, position)` keys, which
    /// are width-independent, so paying for a `Block`'s hashing/geometry (immediately discarded
    /// by the `.map(\.key)` this replaces) on every keep-range boundary crossing during a fling
    /// would be pure waste against the zero-allocation scroll-path invariant. Mirrors
    /// `flatBlocks`' guards exactly (same bail conditions, same shape recognition) so the two
    /// never disagree about which items are flat. Returns `true` when it inserted the full flat
    /// key set into `keys`, `false` on a non-flat shape (nothing inserted) — callers may ignore
    /// the return value if they only care about the accumulated `keys` set.
    @discardableResult
    private func flatBlockKeys<ID: Hashable & Sendable>(
        for table: NodeTable, itemID: ID, into keys: inout Set<BlockKey>
    ) -> Bool {
        guard !table.nodes.isEmpty, case .vstack = table.nodes[0] else { return false }
        let childIndices = table.children(of: 0)
        guard !childIndices.isEmpty, childIndices.count == table.nodes.count - 1 else { return false }
        // Validate the whole shape is flat FIRST, without touching `keys` — a nested container
        // found partway through must bail without partially mutating the caller's accumulator,
        // matching `flatBlocks`' all-or-nothing shape recognition (its nil return likewise
        // discards a half-built `blocks` array). A second, allocation-free pass then inserts
        // directly into `keys` — no intermediate buffer needed since `childIndices` is already
        // materialized.
        for nodeIndex in childIndices {
            switch table.nodes[nodeIndex] {
            case .text, .image, .spacer, .hosting, .gif, .video, .customLayer:
                continue
            case .vstack, .hstack, .zstack:
                return false  // nested container — not flat, bail (matches flatBlocks)
            }
        }
        for position in childIndices.indices {
            keys.insert(BlockKey(itemID: itemID, index: position))
        }
        return true
    }

    /// Synchronous text measurement for the C3 in-place path. The scroll/bind path must never
    /// `await` (CLAUDE.md invariant), so this cannot go through the pooled, actor-isolated
    /// `TextMeasurementPool` that the off-main `RenderPipeline` measure path uses. Matches
    /// `rasterizeText`'s own "fresh TextKit objects per call" pattern (TextRasteriser.swift)
    /// instead of adding a second, synchronous-checkout text-context pool — the C3 path touches
    /// at most one or two text blocks per update (the hot tail, and occasionally one finalized
    /// block), so the allocation is bounded per update, not per block-count.
    private func measureTextSync(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
        #if canImport(XCTest)
        _blockDiffMeasureCallCount += 1
        #endif
        return TextMeasurementContext().measure(descriptor, width: width)
    }

    // MARK: - Frame management

    /// Rebuilds `resolvedFrames` in the current `tables` order.
    /// Heights are read from `oldFrames[s.prevIdx]` for each survivor (prevIdx, nextIdx) pair.
    /// Indices absent from `survivors` fall back to the synchronous `intrinsicHeight(for:width:)`
    /// estimate (real `width / aspectRatio` for single-image rows — no decode, no cache probe),
    /// and only to the flat `estimatedItemHeight` placeholder when intrinsic height can't be
    /// computed (text/mixed/container rows that genuinely need async measurement). Without this,
    /// every unmeasured image row seeds `resolvedFrames` with the flat estimate until the async
    /// pipeline commits — under sustained fast scroll (no warm-up pass) that regime never ends,
    /// so `visRange` churns every frame and the cell pool never converges. See VelocityUI-ksh.
    /// Populates `estimatedIndices` for any index not sourced from a known survivor height —
    /// both intrinsic- and placeholder-seeded rows still need `refineKnownFrames` to reconcile
    /// against the real WorkingRange-committed layout once the pipeline measures them.
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
            } else if let intrinsic = intrinsicHeight(for: tables[i], width: w) {
                h = intrinsic
                estimatedIndices.insert(i)
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

        // Collect out-of-range indices into the pre-allocated scratch buffer,
        // then remove. Dictionary.keys is a lazy non-allocating view; _recycleBuffer
        // reuses its backing store after warm-up — no per-frame allocations.
        _recycleBuffer.removeAll(keepingCapacity: true)
        for index in visibleCells.keys where !keepRange.contains(index) {
            _recycleBuffer.append(index)
        }
        // VelocityUI-socg C4: bound FrozenBitmapStore to the working range — this is the
        // RecyclerView "you are told what left, you don't scan" model `evict(_ keysThatLeft:)`
        // was built for (its own doc). Only pays the `flatBlockKeys` cost for items ACTUALLY
        // leaving this frame (steady state: `_recycleBuffer` is empty, this is a no-op) — never
        // a full-window scan. `flatBlockKeys` (not `flatBlocks`) — only `BlockKey`s are needed
        // here, so there is no reason to build the full `Block`s (contentHash, Fragment, layout)
        // just to immediately discard everything but the key.
        if !_recycleBuffer.isEmpty {
            var leavingKeys: Set<BlockKey> = []
            for index in _recycleBuffer where index < tables.count && index < items.count {
                flatBlockKeys(for: tables[index], itemID: items[index].id, into: &leavingKeys)
            }
            if !leavingKeys.isEmpty {
                environment.frozenBitmapStore.evict(leavingKeys)
            }
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

        // VelocityUI-socg C4: the entering-window counterpart to the eviction above — declares
        // freshly-mounted items' blocks as (newly) in-window so FrozenBitmapStore's `window` set
        // stays accurate for `handleMemoryPressure()`. Only pays `flatBlockKeys`' cost for items
        // that are ACTUALLY newly mounted this pass (the `if let keptCell` branch below
        // `continue`s before reaching this), never for already-resident cells.
        var enteringKeys: Set<BlockKey> = []

        // Mount newly visible cells.
        for index in visRange {
            guard index < resolvedFrames.count, index < tables.count else { continue }
            if let keptCell = visibleCells[index] {
                // VelocityUI-socg C2: a cell kept in-place by itemsDidChange's reuseDecision
                // branch is detached from the layer tree (superlayer == nil) but still bound —
                // reattach it here, in the SAME ascending visRange order a fresh mount uses, so
                // z-order matches display order exactly as a full remount would have produced.
                // A steady-state already-attached cell (the common case) is a single pointer
                // read and `continue` — no allocation, no pool round-trip.
                if keptCell.layer.superlayer == nil {
                    keptCell.layer.frame = resolvedFrames[index]
                    layer.addSublayer(keptCell.layer)
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

        if !enteringKeys.isEmpty {
            environment.frozenBitmapStore.admit(enteringKeys)
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
        let capturedDirection = scrollDirection

        #if canImport(XCTest)
        _taskSpawnCount += 1
        #endif
        environment.pipelineTaskSpawnObserver?()

        Task { [weak self] in
            guard let self else { return }
            await self.pipeline.onIndexBoundary(
                leading,
                workingRange: self.workingRange,
                tables: capturedTables,
                availableWidth: capturedWidth,
                scale: capturedScale,
                direction: capturedDirection
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
    /// `cellPools[kind]?.popLast()` mutates the array in place through the dictionary's
    /// `_modify` accessor — the key is never removed, so a hit never touches the
    /// dictionary's hash table (no rehash/resize). See VelocityUI-9lq: the previous
    /// `removeValue(forKey:)`-then-conditionally-reinsert shape churned the dictionary
    /// backing store (`_NativeDictionary.setValue -> _copyOrMoveAndResize`) every recycle.
    private func dequeue(kind: CellKind) -> RenderCell {
        guard let cell = cellPools[kind]?.popLast() else {
            #if canImport(XCTest)
            _dequeueAllocCount += 1
            #endif
            return RenderCell(kind: kind, placeholderRenderer: environment.placeholderRenderer)
        }
        #if canImport(XCTest)
        _dequeueHitCount += 1
        #endif
        return cell
    }

    /// Returns a cell to its kind's pool.
    ///
    /// `subscript(_:default:)` mutates the array in place through the dictionary's
    /// `_modify` accessor, without ever removing/reinserting the key. See
    /// `dequeue(kind:)`'s docstring — same VelocityUI-9lq fix, symmetric shape.
    private func returnToPool(_ cell: RenderCell) {
        cell.cancelPendingMedia()
        cellPools[cell.kind, default: []].append(cell)
        #if canImport(XCTest)
        _returnToPoolCount += 1
        #endif
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
