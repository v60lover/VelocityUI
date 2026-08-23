// FeedScrollView.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// How far outside the visible viewport a feed keeps content warm — measured, mounted, and
/// prefetched — before the user scrolls there.
///
/// `.screens` is the geometrically correct unit: it degrades to a small item count for a
/// single-column feed (1 item ~= 1 screen) and scales automatically for a grid or masonry layout
/// where items-per-screen varies. `.items` is a fixed item count, independent of viewport
/// geometry — only correct when items-per-screen is roughly constant and known ahead of time
/// (e.g. a fixed single-column list). See `AsyncFeed.prefetchScreens(leading:trailing:)` and
/// `AsyncFeed.prefetchWindow(ahead:behind:)`.
public enum WarmWindow: Sendable, Equatable {
    /// Warm window sized in viewport-height multiples. `leading` = screens to warm ahead in the
    /// scroll direction; `trailing` = screens to keep warm behind. Fractional values allowed
    /// (e.g. `1.5`).
    case screens(leading: CGFloat, trailing: CGFloat)
    /// Warm window sized in item counts, symmetric around the visible range regardless of
    /// scroll direction.
    case items(ahead: Int, behind: Int)
}

/// CALayer-backed vertical feed scroll container.
///
/// Contract: `layoutSubviews` → `updateVisibleCells` is fully synchronous — zero `await`,
/// zero `Task` spawn, zero allocations in steady-state recycling. Pipeline notifications fire
/// only on leading-index boundary crossings.
///
/// `FeedScrollView.layer` is a plain CALayer; cell layers are direct sublayers. UIScrollView
/// scrolls by adjusting `bounds.origin` — no CAScrollLayer override needed.
@MainActor
public final class FeedScrollView<Item: Identifiable & Sendable>: UIScrollView where Item.ID: Sendable {

    // MARK: - Configuration

    /// Builds the DSL node tree for each item. Must be set before assigning `items`.
    public var cellBuilder: (@MainActor (Item) -> any RenderNode)?

    /// How far outside the visible viewport to keep content warm — screens (default) or items.
    /// Set at init — changing after construction requires a new FeedScrollView, since
    /// `warmRange(viewportTop:viewportBottom:)` and pipeline notification both read it directly.
    public let warmWindow: WarmWindow

    /// How many items before the end of the list `onReachEnd` fires.
    /// Independent of `warmWindow` — tuning the prefetch window must not silently move the
    /// page-load trigger.
    public let reachEndThreshold: Int

    /// Called when a user taps a cell. Receives the tapped item and its frame in
    /// scroll-content coordinates.
    public var onTap: (@MainActor (Item, CGRect) -> Void)?

    /// Called when the visible trailing edge nears the end of the item list.
    /// Fired at most once per page; resets when `items.count` grows.
    public var onReachEnd: (@MainActor () async -> Void)?

    /// Opt-in: return a value whose change should invalidate the cached NodeTable for that ID.
    ///
    /// `nil` (default): every `itemsDidChange` rebuilds all NodeTables, unchanged behavior.
    /// Non-nil: items whose signature matches the cached value skip `cellBuilder`+`flatten`
    /// entirely, eliminating the dominant builder+flatten cost for unchanged items.
    ///
    /// Contract (caller's responsibility): if `sig(a) == sig(b)` and `a.id == b.id`, then
    /// `flatten(cellBuilder(a), itemID: a.id)` MUST equal `flatten(cellBuilder(b), itemID: b.id)`.
    /// Violations cause stale UI, not crashes — mirrors SwiftUI's `Equatable` view-identity contract.
    public var itemSignature: ((Item) -> AnyHashable)? = nil

    // MARK: - Items

    /// VelocityUI-socg C4: does NOT diff/relayout synchronously on assignment. A burst of `items`
    /// assignments within one display frame (e.g. token-by-token streaming) coalesces to exactly
    /// ONE `itemsDidChange` call, drained at the top of the next `layoutSubviews()` — see
    /// `_pendingItemsDiffBase`. Leverages UIKit's own `setNeedsLayout`/`layoutSubviews` coalescing
    /// instead of a hand-rolled CADisplayLink. Test pattern `feed.items = X; feed.layoutSubviews()`
    /// still yields exactly one `itemsDidChange` call.
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
    /// shape (`warmRange`'s trailing/behind + visible + leading/ahead), and only after first layout, so
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

    /// Places every item's frame, and tells the scroll path what's visible and how tall the
    /// content is. Defaults to `VerticalLayoutProvider(spacing: layoutSpacing)` — same behavior
    /// as before this was added. Set at init, like `warmWindow` — doesn't change later.
    public let layoutProvider: any LayoutProvider

    // MARK: - Debug hooks

    #if canImport(XCTest)
    /// Counts Task spawns from leading-index boundary crossings inside `notifyPipelineIfNeeded`.
    /// Does NOT count the one-shot `onReachEnd` spawn — that fires at most once per page.
    private(set) var _taskSpawnCount: Int = 0

    /// Mirrors `scrollDirection` as it's set in `layoutSubviews`. Test-only observability for
    /// VelocityUI-im6 — lets tests assert the signal flips from a real `contentOffset.y` delta
    /// without needing to round-trip through `RenderPipeline`/`ImageActor`.
    private(set) var _lastScrollDirection: ScrollDirection = .down

    /// Mirrors the `visRange` computed at the top of `updateVisibleCells()` — the range
    /// FeedScrollView actually used to mount cells for this layout pass. Lets a test compare the
    /// real wired read path against an independently-computed oracle, instead of only inferring
    /// the mounted range indirectly from cell-layer presence.
    private(set) var _lastVisibleRange: Range<Int> = 0..<0

    /// Count of currently-mounted cells. Test-only observability for asserting the mounted set
    /// stays bounded to the working-range window rather than growing with total item count.
    var _visibleCellCount: Int { visibleCells.count }

    /// `WorkingRange.currentRangeStart` passthrough — `workingRange` itself is a private
    /// FeedScrollView property, unreachable from tests without this accessor.
    var _debugWorkingRangeStart: Int { workingRange.currentRangeStart }

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

    /// Exercises the private `warmRange(viewportTop:viewportBottom:)` directly — the same
    /// function `updateVisibleCells`/`notifyPipelineIfNeeded` call on the real scroll path —
    /// against `resolvedFrames` as they stand after the test's own `layoutSubviews()` call.
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
    /// `extractFragments`, using the item's CURRENT `NodeTable`. `nil` if there's no committed
    /// WorkingRange entry or index is out of range. VelocityUI-socg C4: the fast path patches
    /// WorkingRange with a SYNTHETIC `ResolvedLayout` (built from block-diff's resolved
    /// fragments, not a real `measureNode` tree) — this hook lets a test confirm that synthetic
    /// layout round-trips through the same `extractFragments` call sites a later appearance/
    /// media-changed classification would use, rather than only trusting it by inspection.
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

    /// VelocityUI-x4q0: counts calls into the NEW hot-append path
    /// (`environment.hotBlockRasterizerStore.append`). The old two counters above legitimately
    /// stop growing for the hot tail once this path is wired in — this is the correct proxy for
    /// "the incremental rasterizer engaged" now.
    private(set) var _blockDiffHotAppendCallCount: Int = 0

    /// VelocityUI-80uh (B1): counts successful `growHotBlock(_:)` calls — the side-channel
    /// engaged and painted the update without touching `items`/`differ`/`snapshot`. Tests use
    /// this (plus the method's own `Bool` return) to verify the eligibility gate.
    private(set) var _growHotBlockSuccessCount: Int = 0

    /// VelocityUI-80uh (B1): overrides `isGestureActive` for tests. `isTracking`/`isDragging`/
    /// `isDecelerating` are UIKit gesture-recognizer-driven and read-only — there is no way to
    /// set them on a bare, windowless `UIScrollView` without a live touch (same testability gap
    /// BenchmarkHost's `StreamGestureCoalescer` spike solved via closure injection). `nil`
    /// (default) falls back to the real UIKit signals.
    var _debugGestureActiveOverride: Bool?
    #endif

    // MARK: - Init

    /// Designated init.
    ///
    /// - Parameters:
    ///   - environment: Composition root. Only `textPool`, `layoutCache`, `dimensionCache` are
    ///     used here; other collaborators are for downstream beads. Taking the whole
    ///     `RenderEnvironment` is an ergonomic convenience — per-collaborator init is tracked separately.
    ///   - warmWindow: How far outside the visible viewport to keep content warm. Defaults to
    ///     `.items(ahead: 10, behind: 3)` — this type's own historical default, unrelated to
    ///     `AsyncFeed`'s DSL-level default (`.screens(leading: 2, trailing: 1)`), which the DSL
    ///     always passes explicitly.
    ///   - reachEndThreshold: Items before list end that trigger `onReachEnd` — deliberately
    ///     separate from `warmWindow`.
    ///   - estimatedItemHeight: Placeholder height (pt) for unmeasured items; affects initial
    ///     contentSize and visual jump when real layouts land.
    ///   - layoutSpacing: Vertical gap between cells (pt).
    ///   - layoutProvider: Places item frames and drives visibility/content-height. `nil` (default)
    ///     uses `VerticalLayoutProvider(spacing: layoutSpacing)` — today's behavior, unchanged.
    ///     Pass `GridLayoutProvider(columns:spacing:)` for a grid instead.
    ///   - notificationCenter: Source of `UIContentSizeCategory.didChangeNotification` for
    ///     Dynamic Type invalidation (VelocityUI-ezo.2.5). Default `.default` is the one
    ///     system-API singleton exception in CLAUDE.md's no-singletons rule; tests inject a
    ///     private instance for deterministic coverage.
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

    /// `init(frame:)` builds this view before UIKit attaches it to a window, so the
    /// `traitCollection` read at construction reflects the process default, not the live system
    /// setting — traits only propagate once attached. Without this, a user launching with an
    /// accessibility text size would see unscaled text until the next `didChangeNotification`
    /// (posted only on a live change, never on mount). Re-derives the category at the first
    /// reliable read point, routed through `handleContentSizeCategoryChange` so it's a no-op
    /// re-parent when the category hasn't actually changed.
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

        // VelocityUI-socg C3: capture per-block diff inputs for every layout-changed survivor BEFORE
        // workingRange.invalidateAll() wipes the ring buffer — the OLD fragments (real, previously-
        // measured per-block heights) are only readable from WorkingRange right now; once invalidated,
        // recovering them needs a full re-measure, the exact O(item length) cost this diff avoids.
        // `changeSet.layoutChanged` already carries the (prev, next) NodeTable pair, no need to
        // re-derive from `tables`/`nextTables`. Safe under `canDeferInvalidation` too — that path only
        // skips invalidation, never reorders this capture relative to it.
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
            // reuseDecision(oldID:newID:) (Pipeline/ReuseDecision.swift, VelocityUI-0wi) gates recycling
            // here instead of the old unconditional pool-return of every visible cell. `survivors`
            // (built above) already guarantees every prevIdx in `survivorByPrevIdx` is bound to the
            // same item identity as its nextIdx slot (RenderDiffer.diff keys off itemID) — calling
            // reuseDecision explicitly, rather than silently trusting that invariant, makes the
            // decision rule the one source of truth and gives a real branch to unit-test (VelocityUI-socg C2).
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
            // C4: WorkingRange patches for the fast path — populated only when `canDeferInvalidation`,
            // applied after the loop iff every layoutChanged entry resolved. A synthetic ResolvedLayout
            // mirroring what `extractFragments` would derive: root nodeIndex 0 spanning the item
            // (flatBlocks guarantees an unframed root vstack), one child per resolved fragment at
            // nodeIndex == fragment.id / totalFrame == fragment.frame (already item-local, same space
            // `extractFragments` produces) — keeps a later appearanceChanged/mediaChanged
            // classification (which reads `wrEntry.layout`, not `wrEntry.fragments`) correct.
            var blockDiffWorkingRangeCommits: [Int: (layout: ResolvedLayout, fragments: [Fragment])] = [:]
            let width = measureWidth(for: containerWidth)
            let scale = max(1, traitCollection.displayScale)
            for (prevIdx, cell) in visibleCells {
                if let nextIdx = survivorByPrevIdx[prevIdx], nextIdx < tables.count,
                   reuseDecision(oldID: cell.currentItemID, newID: tables[nextIdx].itemID) == .inPlace {
                    // Detach (do not reposition here): survivor indices can shift relative to items
                    // still to be freshly mounted this pass (e.g. a prepend moves this cell from
                    // index 0 to 1 while a new item takes index 0) — reattaching now would leave it
                    // z-ordered ahead of a not-yet-mounted lower index. `updateVisibleCells`' mount
                    // loop re-attaches it in ascending visible-index order, matching display order
                    // without a pool round-trip.
                    cell.layer.removeFromSuperlayer()
                    keptCells[nextIdx] = cell

                    // C3: per-block diff (diff(previous:new:) + freeze application) — unchanged blocks
                    // reused verbatim from FrozenBitmapStore (zero re-measure/rasterize), only the hot
                    // tail / newly-appended blocks touched. `applyInPlaceBlockDiff` returns nil whenever
                    // it can't GUARANTEE correct content cheaply (non-flat item shape, no previous-
                    // fragment baseline, or a changed image/geometry block it can't remeasure) — those
                    // fall through to the pre-existing `_pendingFragmentIndices` full-refresh path,
                    // rather than risk painting wrong/stale content.
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

            // C4: resolve the deferred invalidation decision. `canDeferInvalidation` only established
            // ELIGIBILITY (no add/remove, every layoutChanged entry visible at a stable position) —
            // whether each one actually resolved via block-diff is only known now. All-resolved: patch
            // WorkingRange directly for just those indices, skipping full-window invalidate + pipeline
            // re-measure entirely (a streaming token update no longer forces the whole prefetch window
            // to re-measure). Partial failure: fall back to today's full invalidate + markInvalidated,
            // just decided here instead of upfront — safe since nothing between the original call site
            // and here reads `workingRange` (`applyInPlaceBlockDiff` only consumes `blockDiffInputs`,
            // captured before either branch).
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
        // WorkingRange was patched directly (not invalidated), neighbors untouched. Forcing a
        // re-notify here would only spawn a `notifyPipelineIfNeeded` Task that immediately
        // early-returns inside `onIndexBoundary` (the pipeline's last-notified index was never
        // reset either, since `markInvalidated()` never ran) — a wasted Task + actor hop per
        // streaming token. Leaving the value in place is still correct if the leading index
        // genuinely shifted: `notifyPipelineIfNeeded` compares against it and notifies normally.
        if !tookInPlaceFastPath {
            lastNotifiedLeadingIndex = -1
        }

        syncContentSize()
        setNeedsLayout()
    }

    // MARK: - VelocityUI-socg C3: in-place per-block diff

    /// Attempts the C3 per-block diff for one `.inPlace` survivor: builds previous/new `[Block]`
    /// lists from each side's `NodeTable` (flat shape only, see `flatBlocks(for:width:)`), diffs
    /// them with `diff(previous:new:)`, and re-measures every changed block — freezing it into
    /// `environment.frozenBitmapStore` once it's TEXT and done growing. Returns the item's new
    /// height, its repositioned `[Fragment]` list (so image blocks after a resized text block
    /// still land right), and a `fragment.id -> CGImage` map of every text block's current bitmap
    /// (unchanged blocks hit the resident tier first, then `FrozenBitmapStore`; changed ones are freshly rasterized) —
    /// the caller merges this into `synchronousContent` so `RenderCell.applyLayout` paints real
    /// pixels instead of leaving text blank. `nil` when the update can't be optimized SAFELY —
    /// caller falls back to the `_pendingFragmentIndices` full-refresh path.
    ///
    /// `previousFragments` must be the REAL fragments `extractFragments` produced last time this
    /// item was measured (captured from `WorkingRange` before `invalidateAll()`, see the
    /// `itemsDidChange` call site) — the only source of the old content's real per-block heights,
    /// since `flatBlocks`' synthetic `Fragment`s carry no height of their own.
    ///
    /// `itemID` is `Item.ID`, not `NodeTable.itemID` (`AnyHashable`) — `BlockKey`'s generic init
    /// requires `Hashable & Sendable` and `AnyHashable` isn't `Sendable` here. `.inPlace`
    /// guarantees `previousTable`/`newTable` share identity, so one `itemID` covers both
    /// `flatBlocks` calls below.
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

        // Measures (+ rasterizes) one active TEXT block via the phase-A `freeze(_:)` primitive
        // and keeps its artifact in the resident tier. A fresh, function-scoped `cache`
        // dict is passed on every call so `freeze(_:)` always recomputes here — the PERSISTENT
        // cache is `store`, consulted separately (below) for the genuinely-unchanged case, so
        // this always represents real new work, never a stale hit.
        func measureAndMaybeFreeze(_ block: Block) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text(let descriptor) = block.fragment.content else { return nil }
            // VelocityUI-x4q0: on seal (fence closes / frontier advances over this block), reuse
            // the composited bitmap the hot-append path already produced instead of a fresh
            // measure/rasterize — the sealed-block zero-recompute guarantee for a block that was
            // hot a mo3ment ago. `catchUpAndFinalize` first re-appends `descriptor`'s CURRENT
            // content (cheap incremental blit of just the new tail) so a block that grew further
            // in this same round (self-heal) is caught up before the seal check, instead of
            // mismatching and falling through to a full re-measure. Always tears down the entry
            // (match or no-entry alike), so a stale hot rasterizer never lingers past this call.
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
                    #if canImport(XCTest)
                    _blockDiffRasterizeCallCount += 1
                    #endif
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

        // VelocityUI-x4q0: the hot-append path for the trailing volatile block — routes through
        // `HotBlockRasterizerStore` for O(appended) cost instead of `measureAndMaybeFreeze`'s
        // O(block size) measure/rasterize. Never calls `store.store(...)` — a still-growing
        // block is never persisted into `FrozenBitmapStore`; its current artifact remains in the
        // resident tier until the block leaves the mounted range.
        func measureAndRasterizeHot(_ block: Block) -> (height: CGFloat, bitmap: CGImage?)? {
            guard case .text(let descriptor) = block.fragment.content else { return nil }
            #if canImport(XCTest)
            _blockDiffHotAppendCallCount += 1
            #endif
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
            localFragmentFrames[index] = CGRect(x: 0, y: 0, width: width, height: result.height)
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
        // Positional fallback exposes the volatile tail only through `hot`; unlike the
        // identity-aware path, it does not also classify that index as updated or reused.
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

    /// Recognizes the one item shape this bind-site diff optimizes: a root `.vstack` whose DIRECT
    /// children are all leaves (text/image/spacer/hosting/gif/video/customLayer) — no nesting, no
    /// hstack/zstack — the "VStack of streaming message blocks" shape a chat message produces.
    /// Returns `nil` for any other shape (nested containers, non-vstack root, `.frame()` applied
    /// to the root) so the caller falls back to the full-refresh path instead of a partial,
    /// possibly-wrong optimization for a tree this diff wasn't designed to model (the scoped-down
    /// "minimal reasonable mapping" from VelocityUI-socg C3's design notes).
    ///
    /// Blocks are positioned 0-height placeholders at `width` — real per-block height is filled
    /// in by the caller from measurement/the frozen-bitmap store, never read from these `Fragment`s.
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
            guard let contract = table.blockRenderContract(
                at: nodeIndex, itemID: itemID, positionalIndex: position
            ) else { return nil }
            let frame = CGRect(x: 0, y: 0, width: width, height: 0)
            blocks.append(Block(contract: contract, id: nodeIndex, frame: frame))
        }
        return (blocks, vstackDescriptor.spacing)
    }

    /// Emits just the BlockKeys for the flat-vstack-of-leaves shape `flatBlocks` recognizes,
    /// WITHOUT building any `Block`/`Fragment`/`ResolvedLayout` or computing `contentHash` — the
    /// scroll-path admit/evict window bookkeeping needs only width-independent `(itemID,
    /// position)` keys, so paying for a `Block`'s hashing/geometry (immediately discarded by the
    /// `.map(\.key)` this replaces) on every keep-range boundary crossing during a fling would
    /// violate the zero-allocation scroll-path invariant. Mirrors `flatBlocks`' guards exactly so
    /// the two never disagree about which items are flat. Returns `true` when it inserted the
    /// full flat key set into `keys`, `false` on a non-flat shape (nothing inserted).
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
        for nodeIndex in childIndices where !table.isBlockLeaf(at: nodeIndex) { return false }
        for (position, nodeIndex) in childIndices.enumerated() {
            let key = table.blockID(at: nodeIndex).map { BlockKey(itemID: itemID, blockID: $0) }
                ?? BlockKey(itemID: itemID, index: position)
            keys.insert(key)
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

    // MARK: - VelocityUI-80uh (B1): hot-block side-channel during an active scroll gesture

    /// Whether a scroll gesture is currently in progress — the condition `growHotBlock(_:)`
    /// gates on. Wraps UIKit's own `isTracking`/`isDragging`/`isDecelerating` (gesture-recognizer
    /// driven, read-only) behind one property so tests can override it (see
    /// `_debugGestureActiveOverride`) without a live touch.
    private var isGestureActive: Bool {
        #if canImport(XCTest)
        if let override = _debugGestureActiveOverride { return override }
        #endif
        return isTracking || isDragging || isDecelerating
    }

    /// Grows the trailing hot block of `item` directly, bypassing the full `items` diff/relayout
    /// path — the B1 side-channel (VelocityUI-80uh). Call this INSTEAD OF reassigning `items` on
    /// every streaming token while a scroll gesture is active, passing the item's current value:
    ///
    ///     message.markdownParser.append(token)
    ///     if feed.isTracking || feed.isDragging || feed.isDecelerating {
    ///         _ = feed.growHotBlock(message)   // false: parser still holds the true content,
    ///     } else {                             // next `items =` assignment catches up
    ///         feed.items = messages
    ///     }
    ///
    /// Only applies when `item` is the LAST element of `items` (bottom-growing single-message
    /// case). Above-viewport / multi-message growth (VelocityUI-qgy9) needs contentOffset anchor
    /// compensation instead, and always falls through to a normal `items =` assignment.
    ///
    /// Internally re-runs `applyInPlaceBlockDiff` (VelocityUI-x4q0) — the same per-block diff a
    /// normal `items =` assignment applies — scoped to just this item (`flatten()` runs for
    /// `item` alone; `differ.diff`/`LayoutSnapshot` untouched). Diffs the item's whole block list
    /// every call, so a block-boundary event (new paragraph/code-fence/image/rule) is handled
    /// LIVE during the gesture, not deferred — no separate boundary detector needed (confirmed
    /// by `testBlockBoundary_NewBlockAppearsMidGesture_HandledLiveNotDeferred`; trust that test
    /// over this prose if they disagree).
    ///
    /// `tables[itemIndex]`/`WorkingRange` stay continuously up to date on every successful call,
    /// so nothing needs reconciling at gesture end: the next `items =` assignment re-runs
    /// `applyInPlaceBlockDiff` and finds `HotBlockRasterizerStore` already at the final content —
    /// an empty-delta append, same height/bitmap, no flash.
    ///
    /// - Returns: `true` if the side-channel painted this update (safe to skip `items =`,
    ///   including block-boundary events). `false` if the caller must fall back to `items =` —
    ///   no gesture active, `item` isn't the last item, its cell/WorkingRange isn't primed yet,
    ///   or its shape isn't one `applyInPlaceBlockDiff` optimizes.
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
        if delta != 0 { contentSize.height += delta }
        cell.layer.frame = resolvedFrames[lastIdx]

        var syncMap = buildSyncMap(for: result.fragments, itemID: newTable.itemID)
        for (id, bitmap) in result.textBitmaps { syncMap[id] = bitmap }
        let entering = cell.updateBlockViewport(
            fragments: result.fragments,
            viewportInCell: blockViewport(for: cell.layer.frame),
            synchronousContent: syncMap
        )
        spawnMediaFetches(for: cell, fragments: entering, itemID: newTable.itemID, syncMap: syncMap)

        // Keep `tables`/`WorkingRange` continuously in sync with what's on screen — see doc
        // comment above for why this is what makes the gesture-end reconcile free. Mirrors the
        // exact synthetic-layout shape `itemsDidChange`'s C4 fast path already commits.
        tables[lastIdx] = newTable
        let syntheticLayout = ResolvedLayout(
            totalFrame: CGRect(x: 0, y: 0, width: width, height: result.height),
            children: result.fragments.map { ResolvedLayout(totalFrame: $0.frame, nodeIndex: $0.id) },
            nodeIndex: 0
        )
        workingRange.commit(syntheticLayout, result.fragments, at: lastIdx)

        #if canImport(XCTest)
        _growHotBlockSuccessCount += 1
        #endif
        return true
    }

    // MARK: - Frame management

    /// Rebuilds `resolvedFrames` in the current `tables` order. Heights come from
    /// `oldFrames[s.prevIdx]` for each survivor (prevIdx, nextIdx) pair. Other indices fall back
    /// to the synchronous `intrinsicHeight(for:width:)` estimate (real `width / aspectRatio` for
    /// single-image rows — no decode, no cache probe), and only to the flat `estimatedItemHeight`
    /// placeholder when intrinsic height can't be computed (text/mixed/container rows needing
    /// async measurement). Without the intrinsic fallback, every unmeasured image row would seed
    /// the flat estimate until the async pipeline commits — under sustained fast scroll that
    /// regime never ends, so `visRange` churns every frame and the cell pool never converges
    /// (VelocityUI-ksh). Populates `estimatedIndices` for any index not sourced from a known
    /// survivor height — both intrinsic- and placeholder-seeded rows still need
    /// `refineKnownFrames` to reconcile against the real WorkingRange-committed layout.
    ///
    /// Container width, honoring the first-layout fallback (`bounds.width` until
    /// `lastLayoutWidth` is set by the first `layoutSubviews` pass). This is always the raw,
    /// full width — pass it to `layoutProvider.frames(for:availableWidth:)` and to
    /// `syncContentSize`'s `contentSize.width`, never directly to a measure/cache-key call
    /// (route those through `measureWidth(for:)` instead).
    private var containerWidth: CGFloat {
        lastLayoutWidth > 0 ? lastLayoutWidth : bounds.width
    }

    /// The width to measure a cell's content at, and to key `CacheKey`/`measureNode` calls with —
    /// `layoutProvider.measureWidth(availableWidth:)` applied to a container width. For
    /// `VerticalLayoutProvider` this equals `containerWidth` verbatim (unchanged behavior); for
    /// `GridLayoutProvider` it's the narrower column width. Every measure/
    /// CacheKey call site must route through this so writers and readers never key-mismatch.
    private func measureWidth(for containerWidth: CGFloat) -> CGFloat {
        layoutProvider.measureWidth(availableWidth: containerWidth)
    }

    /// Picking each item's height stays here, since it needs `tables`/`oldFrames`/measurement.
    /// Placing the frames (x/y/width, grid columns included) is handed off to
    /// `layoutProvider.frames(for:availableWidth:)` — we wrap each height in a bare
    /// `ResolvedLayout` and let the provider do the positioning. Safe because every provider's
    /// `frames(for:)` only reads `totalFrame.height` from its input.
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
                // WorkingRange still hasn't been populated by the pipeline for this index (e.g. a
                // fast leading-index advance outran notifyPipelineIfNeeded), but LayoutCache
                // already has the entry — materialize inline, same fallback as
                // updateVisibleCells' WR-miss branch. Gated on _pendingFragmentIndices (the
                // small, mount-bounded set) — NOT on estimatedIndices, which spans the whole feed
                // and would turn this into an NSCache probe + CacheKeyBox allocation per
                // far-off, never-mounted index.
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

    private func syncContentSize() {
        let height = layoutProvider.contentHeight(for: resolvedFrames)
        let target = CGSize(width: containerWidth, height: height)
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

        let visRange = layoutProvider.visibleIndexRange(
            in: resolvedFrames,
            viewportTop: viewportTop,
            viewportBottom: viewportBottom
        )
        #if canImport(XCTest)
        _lastVisibleRange = visRange
        #endif

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

        // Collect out-of-range indices into the pre-allocated scratch buffer,
        // then remove. Dictionary.keys is a lazy non-allocating view; _recycleBuffer
        // reuses its backing store after warm-up — no per-frame allocations.
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
                // VelocityUI-x4q0: same `leavingKeys` set — a live hot rasterizer's
                // `NSTextLayoutManager` must not leak when its cell recycles away.
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

        // Set when a LayoutCache-hit mount below refines resolvedFrames for an index whose
        // real height differs from the estimatedItemHeight placeholder — signals that
        // already-mounted cells at later indices (not touched by this loop, since
        // visibleCells[index] == nil gates re-entry) may need repositioning below.
        var didRefineDuringMount = false

        // Keys of newly mounted cells are promoted after this pass. Existing cache entries move
        // into the resident tier; a cache miss remains a normal pipeline/first-render path.
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
                // WorkingRange miss, but LayoutCache already has the entry (prior pipeline pass at
                // this width, or AsyncFeed.warmUp() before mount). Materialize inline so this cell
                // gets real fragments in THIS layoutSubviews pass instead of a placeholder frame.
                // Subsequent passes hit the WR-hit branch above; refineKnownFrames is bypassed for
                // this index. See WorkingRange.commit's docstring for why a possible double-commit
                // with notifyPipelineIfNeeded's pipeline Task is safe.
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

    /// The index range to keep warm (measured, mounted, prefetched) around the visible viewport —
    /// drives both `updateVisibleCells`'s recycle bounds and the pipeline measure window, so
    /// mounting never asks for an index the pipeline was never told to warm. Same binary-search
    /// primitive as the plain visible-range query, extended geometrically (screens mode) or by a
    /// fixed item count (items mode).
    ///
    /// Runs on the scroll path (`layoutSubviews` → `updateVisibleCells`): allocation-free, O(log n)
    /// — one extra `visibleIndexRange` binary search over the already-built `resolvedFrames`, same
    /// class of work the plain visible-range search already does. No rebuild, no Task, no await.
    private func warmRange(viewportTop: CGFloat, viewportBottom: CGFloat) -> Range<Int> {
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

        // The window actually sent to the pipeline — geometrically wider than `visRange` in
        // screens mode, which is the fix: the trigger (`leading` changing) stays item-based, but
        // the WIDTH of what gets measured now tracks the real viewport, not a fixed item count.
        let capturedWarmRange = warmRange(viewportTop: visTop, viewportBottom: visBottom)
        let capturedTables = tables
        // The measure width, not the raw container width — RenderPipeline's CacheKey/measureNode
        // calls must key on the same width `measureWidth(for:)` produces everywhere else (colWidth
        // under a grid), or its writes silently miss every read site above.
        let capturedWidth  = measureWidth(for: bounds.width)
        let capturedScale  = max(1, traitCollection.displayScale)  // same guard as spawnMediaFetches
        let capturedDirection = scrollDirection

        #if canImport(XCTest)
        _taskSpawnCount += 1
        #endif
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

    /// Phase 2 commit: for each image fragment with a non-nil URL, spawn a Task that fetches and
    /// decodes the image then delivers it to the cell. Called at mount time (WR hit) and from
    /// refineKnownFrames when a WR miss is resolved.
    ///
    /// Task body inherits @MainActor isolation. Cell is captured weakly to prevent a Task → cell
    /// → mediaHandles → Task retain cycle. itemID is captured at spawn time and threaded through
    /// applyContent, which rejects callbacks whose captured itemID doesn't match the cell's
    /// current one.
    ///
    /// `max(1, traitCollection.displayScale)` guards against 0.0 scale for views not yet attached
    /// to a UIWindow (iOS 17+ scene-based traits, unit tests) — a zero scale would produce a
    /// zero-size `ImageCacheKey` and undefined decode behavior; 1× is a safe floor the cache
    /// supersedes on first real-scale hit.
    ///
    /// `syncMap`: fragments already painted synchronously via `applyLayout`'s synchronousContent
    /// map — must not receive a second async fetch (already cached, sublayer already has content).
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
            cell.addMediaHandle(MediaHandle(task: task), for: fragmentID)
        }
    }

    /// Collects synchronously available image and text pixels for a mounted item. Text artifacts
    /// are retained in the resident tier on a cache hit so viewport reconciliation cannot clear them.
    ///
    /// Scale caveat: if preload ran at a different displayScale (e.g. scale 1 in tests,
    /// scale 3 in production), cachedImage returns nil and the fragment is excluded from
    /// the map, silently falling back to the async path. Same constraint as image().
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
