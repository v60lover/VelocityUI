// FeedScrollView.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// How far outside the visible viewport a feed keeps content warm — measured, mounted, and
/// prefetched — before the user scrolls there. `.screens` scales automatically with
/// items-per-screen (grid/masonry-safe); `.items` is a fixed count, only correct when
/// items-per-screen is roughly constant.
public enum WarmWindow: Sendable, Equatable {
    /// Screens to warm ahead (`leading`) and behind (`trailing`) in the scroll direction.
    /// Fractional values allowed (e.g. `1.5`).
    case screens(leading: CGFloat, trailing: CGFloat)
    /// Item counts, symmetric around the visible range regardless of scroll direction.
    case items(ahead: Int, behind: Int)
}

/// CALayer-backed vertical feed scroll container.
///
/// Contract: `layoutSubviews` → `updateVisibleCells` is fully synchronous — zero `await`,
/// zero `Task` spawn, zero allocations in steady-state recycling.
///
/// `layer` is a plain CALayer; cell layers are direct sublayers. UIScrollView scrolls by
/// adjusting `bounds.origin` — no CAScrollLayer override needed.
@MainActor
public final class FeedScrollView<Item: Identifiable & Sendable>: UIScrollView, UIScrollViewDelegate where Item.ID: Sendable {

    // MARK: - Configuration

    /// Builds the DSL node tree for each item. Must be set before assigning `items`.
    public var cellBuilder: (@MainActor (Item) -> any RenderNode)?

    /// How far outside the visible viewport to keep content warm — screens (default) or items.
    /// Set at init; changing later requires a new FeedScrollView.
    public let warmWindow: WarmWindow

    /// How many items before the end of the list `onReachEnd` fires. Independent of
    /// `warmWindow`, so tuning the prefetch window can't silently move the page-load trigger.
    public let reachEndThreshold: Int

    /// Called when a user taps a cell. Receives the tapped item and its frame in
    /// scroll-content coordinates.
    public var onTap: (@MainActor (Item, CGRect) -> Void)?

    /// Called when the visible trailing edge nears the end of the item list.
    /// Fired at most once per page; resets when `items.count` grows.
    public var onReachEnd: (@MainActor () async -> Void)?

    /// Opt-in: return a value whose change should invalidate the cached NodeTable for that ID.
    /// `nil` (default) rebuilds every NodeTable on `itemsDidChange`; non-nil skips
    /// `cellBuilder`+`flatten` for items whose signature is unchanged. Caller's contract: if
    /// `sig(a) == sig(b)` and `a.id == b.id`, then `flatten` must produce the same result for
    /// both — a violation causes stale UI, not a crash.
    public var itemSignature: ((Item) -> AnyHashable)? = nil

    // MARK: - Items

    /// Does NOT diff/relayout synchronously on assignment. A burst of assignments within one
    /// display frame (e.g. token-by-token streaming) coalesces to exactly one `itemsDidChange`
    /// call, drained at the top of the next `layoutSubviews()` — see `_pendingItemsDiffBase`.
    public var items: [Item] = [] {
        didSet {
            if _pendingItemsDiffBase == nil {
                _pendingItemsDiffBase = oldValue
            }
            setNeedsLayout()
        }
    }

    /// The pre-burst `items` value to diff FROM once `layoutSubviews()` drains the coalesced
    /// update. Captured only on the first assignment of a burst so later assignments can't
    /// overwrite the true baseline. `nil` in steady state.
    private var _pendingItemsDiffBase: [Item]?

    // MARK: - Dependencies

    private let pipeline: RenderPipeline
    let workingRange: WorkingRange
    private let differ: RenderDiffer
    private let environment: RenderEnvironment

    /// Read-only view of the composition root.
    /// Exposed for external lifecycle coordination and test double injection.
    public var renderEnvironment: RenderEnvironment { environment }

    // MARK: - State

    /// NodeTables in display order. Parallel to `items`.
    var tables: [NodeTable] = []
    /// Absolute frames in scroll-content coordinates. Parallel to `items`.
    var resolvedFrames: [CGRect] = []
    /// Previous snapshot passed to RenderDiffer.
    private var snapshot: LayoutSnapshot = LayoutSnapshot(tables: [])

    /// Indices whose heights are estimated (not yet confirmed by WorkingRange).
    /// `refineKnownFrames()` iterates this set; it is empty in steady state.
    private var estimatedIndices: Set<Int> = []

    var visibleCells: [Int: RenderCell] = [:]
    private var cellPools: [CellKind: [RenderCell]] = [:]

    /// Leading index sent to pipeline on last boundary crossing.
    private var lastNotifiedLeadingIndex: Int = -1

    /// `contentOffset.y` observed on the previous `layoutSubviews` pass. Compared against
    /// the current value each pass to derive `scrollDirection` from a real scroll metric.
    private var lastScrollOffsetY: CGFloat = 0

    /// Content-height growth that was withheld while an edge rubber-band (bounce) was active.
    /// `resolvedFrames` already reflects this growth — the tail keeps painting; this is only the
    /// portion not yet written to `contentSize.height`. Committed in one write once the scroll
    /// leaves the bounce region. Writing `contentSize.height` mid-bounce moves the animation's
    /// target and jumps the viewport, so the write is deferred, not the paint.
    var _deferredContentSizeDelta: CGFloat = 0

    /// Direction of travel along the scroll axis, from the sign of the `contentOffset.y` delta.
    /// Holds its last value at rest (avoids flicker at rubber-band edges). Threaded into
    /// `pipeline.onIndexBoundary(direction:)` so ahead/behind prefetch classification tracks
    /// actual travel direction.
    var scrollDirection: ScrollDirection = .down

    private var lastLayoutWidth: CGFloat = 0
    /// False until the first `layoutSubviews` width transition has been handled. Distinguishes
    /// the initial `0 -> bounds.width` sentinel (nothing stale to evict) from a genuine width
    /// change (rotation/resize), where prior-width entries ARE stale.
    private var hasLaidOutOnce: Bool = false
    private var reachEndFired: Bool = false

    /// Dynamic Type category threaded into every `flatten()` call. Initialized from the live
    /// trait environment at `init` so mount-time already reflects the system setting, rather
    /// than defaulting to `.unspecified` until the first change notification fires.
    private var contentSizeCategory: VContentSizeCategory = .unspecified
    private let notificationCenter: NotificationCenter
    private var contentSizeCategoryObserver: NSObjectProtocol?

    /// Pre-allocated scratch buffer for the recycle loop — avoids a per-frame Array allocation.
    private var _recycleBuffer: [Int] = []

    /// Largest `keepRange.count` seen so far; resizes `FrozenBitmapStore`'s byte budget once it
    /// grows. Tracked monotonically-up so a transient shrink (e.g. rotation) never shrinks the
    /// live budget mid-scroll and thrash-evicts blocks still inside the window.
    private var _frozenBudgetWindowCount: Int = 0

    /// Pre-allocated scratch buffer for `refineKnownFrames` — avoids a fresh Set.union +
    /// Array.sorted allocation on every call while indices remain unrefined.
    private var _refineIndexBuffer: [Int] = []

    /// Indices where the cell was mounted with applyLayout([]) during a WorkingRange miss.
    /// refineKnownFrames delivers real fragments and spawns media fetches when entries arrive.
    var _pendingFragmentIndices: Set<Int> = []

    var tableCache: [Item.ID: (sig: AnyHashable, table: NodeTable)] = [:]

    /// Placeholder height for items not yet measured by the pipeline.
    /// Affects the initial contentSize and the scroll distance to the first real layout.
    /// Tunable via init — useful when content is known to be significantly taller or shorter than 300 pt.
    public let estimatedItemHeight: CGFloat

    /// Vertical gap between adjacent cells in scroll-content coordinates.
    public let layoutSpacing: CGFloat

    /// Places every item's frame, and tells the scroll path what's visible and how tall the
    /// content is. Defaults to `VerticalLayoutProvider(spacing: layoutSpacing)` — same behavior
    /// as before this was added. Set at init, like `warmWindow` — doesn't change later.
    public let layoutProvider: any LayoutProvider

    // MARK: - Test hooks

    /// Container for test-only observability/override state that can't live in
    /// `FeedScrollView+TestHooks.swift` as an extension (extensions forbid stored instance
    /// properties). Always present — see the type's own docstring for why it isn't `#if`-gated.
    let _testHooks = FeedScrollViewTestHooks()

    // MARK: - Init

    /// Designated init.
    ///
    /// - Parameters:
    ///   - environment: Composition root; only `textPool`, `layoutCache`, `dimensionCache` used here.
    ///   - warmWindow: How far outside the visible viewport to keep content warm. Defaults to
    ///     `.items(ahead: 10, behind: 3)`; `AsyncFeed` always passes its own default explicitly.
    ///   - reachEndThreshold: Items before list end that trigger `onReachEnd`.
    ///   - estimatedItemHeight: Placeholder height (pt) for unmeasured items.
    ///   - layoutSpacing: Vertical gap between cells (pt).
    ///   - layoutProvider: Places item frames and drives visibility/content-height. `nil`
    ///     (default) uses `VerticalLayoutProvider(spacing: layoutSpacing)`.
    ///   - notificationCenter: Source of `UIContentSizeCategory.didChangeNotification` for
    ///     Dynamic Type invalidation. Default `.default` is the one system-API singleton
    ///     exception in CLAUDE.md's no-singletons rule; tests inject a private instance.
    public init(
        environment: RenderEnvironment,
        frame: CGRect = .zero,
        warmWindow: WarmWindow = .items(ahead: 10, behind: 3),
        reachEndThreshold: Int = 3,
        estimatedItemHeight: CGFloat = 300,
        layoutSpacing: CGFloat = 8,
        layoutProvider: (any LayoutProvider)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.environment = environment
        self.warmWindow = warmWindow
        self.reachEndThreshold = reachEndThreshold
        self.estimatedItemHeight = estimatedItemHeight
        self.layoutSpacing = layoutSpacing
        self.layoutProvider = layoutProvider ?? VerticalLayoutProvider(spacing: layoutSpacing)
        self.notificationCenter = notificationCenter
        self.pipeline = RenderPipeline(
            textPool: environment.textPool,
            layoutCache: environment.layoutCache,
            imageActor: environment.imageActor,
            frozenBitmapStore: environment.frozenBitmapStore
        )
        self.workingRange = WorkingRange()
        self.differ = RenderDiffer(dimensionCache: environment.dimensionCache)
        super.init(frame: frame)
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        // Self-delegate purely to catch bounce/deceleration end (the deferred-contentSize flush,
        // below). VelocityUI otherwise makes no use of the scroll delegate.
        delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        contentSizeCategory = VContentSizeCategory(traitCollection.preferredContentSizeCategory)
        // queue: nil — the OS always posts this on main, keeping delivery synchronous and
        // consistent with "scroll path never awaits".
        contentSizeCategoryObserver = notificationCenter.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            // Extracted here (nonisolated) rather than inside MainActor.assumeIsolated below:
            // Swift 6 region isolation rejects sending the non-Sendable Notification across the
            // hop, but the extracted Sendable value crosses fine.
            let uiCategory = note.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? UIContentSizeCategory
            guard let self else { return }
            MainActor.assumeIsolated { self.handleContentSizeCategoryChange(uiCategory: uiCategory) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(environment:frame:)") }

    deinit {
        // deinit isn't a recycle path — visibleCells never pass through returnToPool, so their
        // decode Tasks are cancelled here instead. assumeIsolated is safe: this type is
        // @MainActor, so deinit always runs on main.
        MainActor.assumeIsolated {
            for cell in visibleCells.values { cell.cancelPendingMedia() }
            if let contentSizeCategoryObserver {
                notificationCenter.removeObserver(contentSizeCategoryObserver)
            }
        }
    }

    // MARK: - Dynamic Type

    /// Reads the new category from the notification's payload rather than unconditionally
    /// re-reading `traitCollection.preferredContentSizeCategory` — this is what makes it testable
    /// without a real trait-collection override; falls back to the live trait if payload is missing.
    private func handleContentSizeCategoryChange(uiCategory: UIContentSizeCategory?) {
        let newCategory = VContentSizeCategory(uiCategory ?? traitCollection.preferredContentSizeCategory)
        guard newCategory != contentSizeCategory else { return }
        contentSizeCategory = newCategory
        // itemSignature's cached tables were flattened at the old category and don't encode it,
        // so clear the cache to force every item back through flatten() at the new category.
        tableCache.removeAll(keepingCapacity: true)
        itemsDidChange(from: items)
    }

    /// `init(frame:)` builds this view before UIKit attaches it to a window, so
    /// `traitCollection` at construction reflects the process default, not the live setting.
    /// Re-derives the category at the first reliable read point (window attach).
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        handleContentSizeCategoryChange(uiCategory: traitCollection.preferredContentSizeCategory)
    }

    // MARK: - Layout

    override public func layoutSubviews() {
        super.layoutSubviews()

        // Commit any height growth withheld during an edge bounce, now that the bounce has
        // settled — before anything below reads or writes contentSize this pass. The bounce
        // animation already drives a layoutSubviews pass every frame, so relying on it (rather
        // than forcing extra passes with setNeedsLayout) is what keeps the main thread free —
        // forcing layout here would starve the deceleration and hang at the edge.
        flushDeferredContentSizeIfNeeded()

        // Drain any coalesced `items` burst first — refineKnownFrames/updateVisibleCells below
        // read state that only itemsDidChange updates. itemsDidChange clears
        // _pendingItemsDiffBase itself, so this can't double-drain.
        if let base = _pendingItemsDiffBase {
            itemsDidChange(from: base)
        }

        let offsetY = contentOffset.y
        if offsetY != lastScrollOffsetY {
            scrollDirection = offsetY > lastScrollOffsetY ? .down : .up
            lastScrollOffsetY = offsetY
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
        // Cleared unconditionally regardless of call site — any call fully resyncs
        // snapshot/tables to the current items, so a pending marker is always stale afterward.
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
        // Covers all items with a known previous height. Int-keyed — zero AnyHashable boxing.
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

        // Set only by the fully-resolved fast path below (every layoutChanged entry patched
        // WorkingRange directly, no invalidation) — gates the `lastNotifiedLeadingIndex` reset
        // near the end of this method.
        var tookInPlaceFastPath = false

        if needsFullInvalidation {
            // reuseDecision gates recycling explicitly rather than trusting that survivors always
            // match identity — makes the decision rule the one source of truth and testable.
            var survivorByPrevIdx: [Int: Int] = [:]
            survivorByPrevIdx.reserveCapacity(survivors.count)
            for s in survivors { survivorByPrevIdx[s.prevIdx] = s.nextIdx }

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
                if let nextIdx = survivorByPrevIdx[prevIdx], nextIdx < tables.count,
                   reuseDecision(oldID: cell.currentItemID, newID: tables[nextIdx].itemID) == .inPlace {
                    // Detach without repositioning: survivor indices can shift relative to items
                    // still to be mounted this pass (e.g. a prepend). updateVisibleCells' mount
                    // loop re-attaches in ascending visible-index order to preserve z-order.
                    cell.layer.removeFromSuperlayer()
                    keptCells[nextIdx] = cell

                    // Per-block diff: unchanged blocks reused verbatim from FrozenBitmapStore,
                    // only the hot tail touched. Returns nil when it can't guarantee correct
                    // content cheaply, falling through to the full-refresh path.
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
                        applyContentHeightDelta(delta)
                        estimatedIndices.remove(nextIdx)
                        cell.layer.frame = resolvedFrames[nextIdx]
                        // Merge image cache hits with the block-diff's freshly-resolved text
                        // bitmaps — fragment ids never collide across content kinds within one
                        // item's NodeTable, so a plain overwrite-merge is safe.
                        var syncMap = buildSyncMap(for: result.fragments, itemID: inputs.newTable.itemID)
                        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
                        let entering = cell.updateBlockViewport(
                            fragments: result.fragments,
                            viewportInCell: blockViewport(for: cell.layer.frame),
                            synchronousContent: syncMap
                        )
                        spawnMediaFetches(for: cell, fragments: entering, itemID: inputs.newTable.itemID,
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

            // Resolve the deferred invalidation decision: canDeferInvalidation only established
            // eligibility; whether each entry actually resolved via block-diff is known only now.
            // All-resolved: patch WorkingRange directly, skipping full-window invalidate + pipeline
            // re-measure. Partial failure: fall back to full invalidate + markInvalidated.
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
            // Re-enroll every kept .inPlace index (except ones the block-diff path already
            // resolved) so refineKnownFrames refreshes content once WorkingRange recommits.
            // Without this, a same-id survivor freezes on stale content until it re-mounts.
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

        // On the fully-resolved fast path, WorkingRange was patched directly (not invalidated),
        // so nothing needs a pipeline re-measure. Re-notifying would just spawn a wasted Task
        // that early-returns inside onIndexBoundary.
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
              previousBlocks.count == previousFragments.count,
              !newBlocks.isEmpty
        else { return nil }

        let trailingIndex = newBlocks.count - 1
        let d = diff(previous: previousBlocks, new: newBlocks)
        let store = environment.frozenBitmapStore
        let residentStore = environment.visibleBlockStore

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
            if case .text = block.fragment.content {
                if case .text(let descriptor) = block.fragment.content,
                   let sealed = environment.hotBlockRasterizerStore.catchUpAndFinalize(
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
                } else if let size = residentStore.size(for: block.key),
                          let bitmap = residentStore.bitmap(for: block.key) {
                    recordTextResult((size.height, bitmap), for: block, at: match.newIndex)
                } else if let size = store.size(for: block.key) {
                    // A cached inactive block becomes resident before a later token can make it
                    // an LRU victim. The same bitmap instance is painted without re-rasterizing.
                    let bitmap = store.bitmap(for: block.key)
                    if let bitmap { residentStore.store(bitmap, size: size, for: block.key) }
                    recordTextResult((size.height, bitmap), for: block, at: match.newIndex)
                } else {
                    // Self-heal: logically unchanged per diff(), but the store has no entry
                    // yet (first pass through C3 for this block, or it was LRU/pressure-
                    // evicted) — recompute once and (re-)freeze it, same as a finalized tail.
                    guard let result = measureAndMaybeFreeze(block) else { return nil }
                    recordTextResult(result, for: block, at: match.newIndex)
                }
            } else {
                if let geometry = resolveDeterministicGeometry(block) {
                    recordGeometry(geometry, at: match.newIndex)
                } else {
                    // Measured non-text has no synchronous geometry contract. Preserve the real
                    // prior fragment just as the pre-resolver path did for unchanged content.
                    let previousFrame = previousFragments[match.previousIndex].frame
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
            let removed = Set(d.removed)
            store.evict(removed)
            residentStore.evict(removed)
            environment.hotBlockRasterizerStore.evict(removed)
        }

        var cursor: CGFloat = 0
        var fragments: [Fragment] = []
        fragments.reserveCapacity(newBlocks.count)
        for (i, block) in newBlocks.enumerated() {
            let localFrame = localFragmentFrames[i].isNull
                ? CGRect(x: 0, y: 0, width: width, height: heights[i])
                : localFragmentFrames[i]
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
    @discardableResult
    private func flatBlockKeys<ID: Hashable & Sendable>(
        for table: NodeTable, itemID: ID, into keys: inout Set<BlockKey>
    ) -> Bool {
        guard !table.nodes.isEmpty, case .vstack = table.nodes[0] else { return false }
        let childIndices = table.children(of: 0)
        guard !childIndices.isEmpty, childIndices.count == table.nodes.count - 1 else { return false }
        // Validate the whole shape is flat first, without touching `keys` — a nested container
        // found partway through must bail without partially mutating the caller's accumulator.
        for nodeIndex in childIndices where !table.isBlockLeaf(at: nodeIndex) { return false }
        for (position, nodeIndex) in childIndices.enumerated() {
            let key = table.blockID(at: nodeIndex).map { BlockKey(itemID: itemID, blockID: $0) }
                ?? BlockKey(itemID: itemID, index: position)
            keys.insert(key)
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
        let syntheticLayout = ResolvedLayout(
            totalFrame: CGRect(x: 0, y: 0, width: width, height: result.height),
            children: result.fragments.map { ResolvedLayout(totalFrame: $0.frame, nodeIndex: $0.id) },
            nodeIndex: 0
        )
        workingRange.commit(syntheticLayout, result.fragments, at: lastIdx)

        _testHooks.growHotBlockSuccessCount += 1
        return true
    }

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
    private var containerWidth: CGFloat {
        lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
    }

    /// The width to measure a cell's content at, and to key `CacheKey`/`measureNode` calls with.
    /// For `VerticalLayoutProvider` this equals `containerWidth`; for `GridLayoutProvider` it's
    /// the narrower column width. Every measure/CacheKey call site must route through this so
    /// writers and readers never key-mismatch.
    private func measureWidth(for containerWidth: CGFloat) -> CGFloat {
        layoutProvider.measureWidth(availableWidth: containerWidth)
    }

    /// Picks each item's height (needs `tables`/`oldFrames`/measurement), then hands positioning
    /// off to `layoutProvider.frames(for:availableWidth:)` — safe because every provider only
    /// reads `totalFrame.height` from its input.
    private func rebuildFrames(oldFrames: [CGRect], survivors: [(prevIdx: Int, nextIdx: Int)]) {
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
                let syncMap = buildSyncMap(for: entry.fragments, itemID: tables[index].itemID)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: cell.layer.frame),
                    synchronousContent: syncMap
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
    private func applyContentHeightDelta(_ delta: CGFloat) {
        guard delta != 0 else { return }
        if isInTopBounceRegion {
            _deferredContentSizeDelta += delta
        } else {
            contentSize.height += delta
        }
    }

    /// True when no gesture or bounce animation is in flight — nothing left to perturb, so a
    /// deferred height write is safe to commit even if `contentOffset` still sits at the edge.
    private var isScrollAtRest: Bool {
        if let override = _testHooks.scrollAtRestOverride { return override }
        return !isTracking && !isDragging && !isDecelerating
    }

    /// Commits any height growth withheld during an edge bounce, in a single write. Fires once the
    /// scroll has left the bounce region OR the scroll has come to rest. The at-rest branch is
    /// essential: a rubber-band settle can land exactly at the frozen edge (`isInBounceRegion`
    /// still true by rounding) without ever producing an out-of-bounce layout pass. Without it the
    /// growth strands until the user manually scrolls — and at the bottom, with `contentSize`
    /// frozen, the only possible direction is up, which was the reported bug.
    private func flushDeferredContentSizeIfNeeded() {
        guard _deferredContentSizeDelta != 0, !isInBounceRegion || isScrollAtRest else { return }
        contentSize.height += _deferredContentSizeDelta
        _deferredContentSizeDelta = 0
    }

    // MARK: - Scroll-settle delegate (deferred contentSize flush)

    /// The reliable "edge rubber-band has settled" signal. Commit the withheld growth in one write
    /// here — a single flush, not the per-frame `setNeedsLayout` that would starve the bounce
    /// animation and hang the edge. `layoutSubviews`' own flush covers the streaming-active case;
    /// this covers a settle with no token arriving to drive a layout pass.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushDeferredContentSizeIfNeeded()
    }

    /// Finger lifted without a subsequent deceleration (released at rest) — same one-shot flush.
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { flushDeferredContentSizeIfNeeded() }
    }

    private func syncContentSize() {
        // In an edge bounce, defer: writing the authoritative height now perturbs the animation.
        // resolvedFrames stays truthful, so the post-settle flush lands the correct height.
        guard !isInBounceRegion else { return }
        let height = layoutProvider.contentHeight(for: resolvedFrames)
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
    private func handleWidthChange(isFirstLayout: Bool) {
        if !isFirstLayout {
            workingRange.invalidateAll()
            let pipeline = self.pipeline
            Task { await pipeline.markInvalidated() }
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

    // MARK: - Synchronous scroll path

    /// Called from `layoutSubviews`. ZERO await on the scroll path itself.
    /// Media fetch Tasks are spawned at cell-mount time (a state change, not per frame).
    /// Returns the computed visible range so the caller can pass it to `checkReachEnd`.
    @discardableResult
    private func updateVisibleCells() -> Range<Int> {
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
                // A live hot rasterizer's NSTextLayoutManager must not leak when its cell recycles away.
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
                    let syncMap = buildSyncMap(for: entry.fragments, itemID: tables[index].itemID)
                    let entering = keptCell.updateBlockViewport(
                        viewportInCell: blockViewport(for: keptCell.layer.frame),
                        synchronousContent: syncMap
                    )
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
                let syncMap = buildSyncMap(for: entry.fragments, itemID: table.itemID)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: frame),
                    synchronousContent: syncMap
                )
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
                let syncMap = buildSyncMap(for: entry.fragments, itemID: table.itemID)
                let entering = cell.updateBlockViewport(
                    fragments: entry.fragments,
                    viewportInCell: blockViewport(for: mountFrame),
                    synchronousContent: syncMap
                )
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
    private func blockViewport(for cellFrame: CGRect) -> CGRect {
        let prefetch = bounds.height
        return CGRect(
            x: 0,
            y: contentOffset.y - cellFrame.minY - prefetch,
            width: cellFrame.width,
            height: bounds.height + (2 * prefetch)
        )
    }

    // MARK: - Pipeline notification

    private func notifyPipelineIfNeeded() {
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
    /// `cellPools[kind]?.popLast()` mutates the array in place via the dictionary's `_modify`
    /// accessor — the key is never removed, so a hit never touches the hash table.
    private func dequeue(kind: CellKind) -> RenderCell {
        guard let cell = cellPools[kind]?.popLast() else {
            _testHooks.dequeueAllocCount += 1
            return RenderCell(kind: kind, placeholderRenderer: environment.placeholderRenderer)
        }
        _testHooks.dequeueHitCount += 1
        return cell
    }

    /// Returns a cell to its kind's pool. `subscript(_:default:)` mutates the array in place
    /// via `_modify`, without ever removing/reinserting the key — same shape as `dequeue(kind:)`.
    private func returnToPool(_ cell: RenderCell) {
        cell.cancelPendingMedia()
        cellPools[cell.kind, default: []].append(cell)
        _testHooks.returnToPoolCount += 1
    }

    // MARK: - Media pipeline

    /// For each image fragment with a non-nil URL, spawn a Task that fetches and decodes the
    /// image then delivers it to the cell. Called at mount time and from refineKnownFrames.
    ///
    /// Cell is captured weakly to prevent a retain cycle. itemID is captured at spawn time and
    /// threaded through applyContent, which rejects callbacks whose itemID doesn't match the
    /// cell's current one.
    ///
    /// `max(1, traitCollection.displayScale)` guards against 0.0 scale for views not yet
    /// attached to a UIWindow — a zero scale would produce an undefined decode.
    ///
    /// `syncMap`: fragments already painted synchronously via `applyLayout` — must not receive a
    /// second async fetch.
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
                // Primary defence on the fast-scroll path: MediaHandle.cancel() marks the Task
                // cancelled before prepareForReuse rebinds the cell, but imageActor.image() may
                // still return if the semaphore was already acquired. applyContent's itemID
                // guard is the defense-in-depth backup for races after this check.
                guard !Task.isCancelled else { return }
                if let transition = cell?.applyContent(id: fragmentID, image: img, for: itemID) {
                    contentDeliveryObserver?(transition)
                }
            }
            cell.addMediaHandle(MediaHandle(task: task), for: fragmentID)
        }
    }

    /// Collects synchronously available image and text pixels for a mounted item. Text artifacts
    /// are retained in the resident tier on a cache hit so viewport reconciliation can't clear them.
    ///
    /// Scale caveat: if preload ran at a different displayScale, cachedImage returns nil and the
    /// fragment silently falls back to the async path.
    private func buildSyncMap(for fragments: [Fragment], itemID: AnyHashable) -> [Int: CGImage] {
        let imageActor = environment.imageActor
        let residentStore = environment.visibleBlockStore
        let frozenStore = environment.frozenBitmapStore
        let scale = max(1, traitCollection.displayScale)
        var map: [Int: CGImage] = [:]
        for (position, fragment) in fragments.enumerated() {
            switch fragment.content {
            case .image(let descriptor):
                guard let url = descriptor.url else { continue }
                if let image = imageActor.cachedImage(
                    for: url,
                    targetSize: fragment.frame.size,
                    cornerRadius: descriptor.cornerRadius,
                    scale: scale
                ) {
                    map[fragment.id] = image
                }
            case .text:
                let key = BlockKey(
                    boxedItemID: itemID,
                    index: position,
                    blockID: fragment.blockID
                )
                if let image = residentStore.bitmap(for: key) {
                    map[fragment.id] = image
                } else if let size = frozenStore.size(for: key),
                          let image = frozenStore.bitmap(for: key) {
                    residentStore.store(image, size: size, for: key)
                    frozenStore.evict([key])
                    map[fragment.id] = image
                }
            case .geometry:
                continue
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
