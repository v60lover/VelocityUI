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
    var _pendingItemsDiffBase: [Item]?

    // MARK: - Dependencies

    let pipeline: RenderPipeline
    let workingRange: WorkingRange
    let differ: RenderDiffer
    let environment: RenderEnvironment

    /// Read-only view of the composition root.
    /// Exposed for external lifecycle coordination and test double injection.
    public var renderEnvironment: RenderEnvironment { environment }

    // MARK: - State

    /// NodeTables in display order. Parallel to `items`.
    var tables: [NodeTable] = []
    /// Absolute frames in scroll-content coordinates. Parallel to `items`.
    var resolvedFrames: [CGRect] = []
    /// Previous snapshot passed to RenderDiffer.
    var snapshot: LayoutSnapshot = LayoutSnapshot(tables: [])

    /// Indices whose heights are estimated (not yet confirmed by WorkingRange).
    /// `refineKnownFrames()` iterates this set; it is empty in steady state.
    var estimatedIndices: Set<Int> = []

    var visibleCells: [Int: RenderCell] = [:]

    /// Owns cell recycling (dequeue/returnToPool) — see `CellPool`.
    let cellPool: CellPool

    /// Owns media fan-out (spawnMediaFetches/buildSyncMap) — see `MediaDispatcher`.
    let mediaDispatcher: MediaDispatcher

    /// Leading index sent to pipeline on last boundary crossing.
    var lastNotifiedLeadingIndex: Int = -1

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

    var lastLayoutWidth: CGFloat = 0
    /// False until the first `layoutSubviews` width transition has been handled. Distinguishes
    /// the initial `0 -> bounds.width` sentinel (nothing stale to evict) from a genuine width
    /// change (rotation/resize), where prior-width entries ARE stale.
    private var hasLaidOutOnce: Bool = false
    var reachEndFired: Bool = false

    /// Dynamic Type category threaded into every `flatten()` call. Initialized from the live
    /// trait environment at `init` so mount-time already reflects the system setting, rather
    /// than defaulting to `.unspecified` until the first change notification fires.
    var contentSizeCategory: VContentSizeCategory = .unspecified
    private let notificationCenter: NotificationCenter
    private var contentSizeCategoryObserver: NSObjectProtocol?

    /// Pre-allocated scratch buffer for the recycle loop — avoids a per-frame Array allocation.
    var _recycleBuffer: [Int] = []

    /// Largest `keepRange.count` seen so far; resizes `FrozenBitmapStore`'s byte budget once it
    /// grows. Tracked monotonically-up so a transient shrink (e.g. rotation) never shrinks the
    /// live budget mid-scroll and thrash-evicts blocks still inside the window.
    var _frozenBudgetWindowCount: Int = 0

    /// Pre-allocated scratch buffer for `refineKnownFrames` — avoids a fresh Set.union +
    /// Array.sorted allocation on every call while indices remain unrefined.
    var _refineIndexBuffer: [Int] = []

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
            frozenBitmapStore: environment.frozenBitmapStore,
            highlightRegistry: environment.highlightRegistry,
            codeBodyRetokenizeObserver: environment.codeBodyRetokenizeObserver
        )
        self.workingRange = WorkingRange()
        self.differ = RenderDiffer(dimensionCache: environment.dimensionCache)
        self.cellPool = CellPool(placeholderRenderer: environment.placeholderRenderer)
        self.mediaDispatcher = MediaDispatcher(
            imageActor: environment.imageActor,
            visibleBlockStore: environment.visibleBlockStore,
            frozenBitmapStore: environment.frozenBitmapStore,
            contentDeliveryObserver: environment.contentDeliveryObserver
        )
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
