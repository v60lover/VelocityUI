// AsyncFeed.swift

#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI entry point for VelocityUI feeds.
///
/// Deliberately not `Equatable`: `.equatable()`'s skip path would leave Coordinator's
/// `onTap`/`onReachEnd` closures stale, since closures aren't Equatable. `updateUIView`'s own
/// structural guard already makes the "items unchanged" case cheap.
@MainActor
public struct AsyncFeed<
    Item: Identifiable & Sendable & Equatable,
    Cell: RenderView
>: UIViewRepresentable where Item.ID: Sendable {

    // MARK: - Stored properties (value-type copies for modifier chaining)

    private let items: [Item]
    private let environment: RenderEnvironment
    private let layout: GridLayout
    private let cellBuilder: @MainActor (Item) -> Cell
    private var warmWindow: WarmWindow = .screens(leading: 2, trailing: 1)
    private var reachEndThreshold: Int = 3
    private var onTap: (@MainActor (Item, CGRect) -> Void)? = nil
    private var onReachEnd: (@MainActor () async -> Void)? = nil

    // MARK: - Init

    /// Creates a feed backed by the given items.
    ///
    /// - Parameters:
    ///   - items: Updated on every parent body call; unchanged arrays skip rebuild via identity + equality guards.
    ///   - environment: Composition root — construct once (e.g. `@State`) and reuse across re-renders.
    ///   - layout: Layout strategy. Captured at view identity — changing after mount needs a `.id()` rebuild.
    ///   - cellBuilder: Runs on `@MainActor` once per item change; flattened to a `NodeTable` immediately.
    public init(
        items: [Item],
        environment: RenderEnvironment,
        layout: GridLayout = .vertical(),
        cellBuilder: @escaping @MainActor (Item) -> Cell
    ) {
        self.items = items
        self.environment = environment
        self.layout = layout
        self.cellBuilder = cellBuilder
    }

    // MARK: - Modifiers

    /// Sets a fixed-item-count warm window, opting out of the default screens-based window. Only
    /// correct when items-per-screen is roughly constant — under a grid or masonry layout, prefer
    /// `prefetchScreens(leading:trailing:)`. Captured at view identity; last-modifier-wins if chained
    /// with `prefetchScreens`.
    public func prefetchWindow(ahead: Int, behind: Int) -> Self {
        var copy = self
        copy.warmWindow = .items(ahead: ahead, behind: behind)
        return copy
    }

    /// Sets the warm window geometrically, in screens (viewport-height multiples) — the recommended
    /// path and the default (`leading: 2, trailing: 1`). Works uniformly across vertical, grid, and
    /// masonry layouts since the window is a rectangle, not an item count. Captured at view identity;
    /// last-modifier-wins if chained with `prefetchWindow`.
    public func prefetchScreens(leading: CGFloat, trailing: CGFloat) -> Self {
        var copy = self
        copy.warmWindow = .screens(leading: leading, trailing: trailing)
        return copy
    }

    /// Sets how many items from the end of the list trigger `onReachEnd`. In `prefetchWindow`
    /// (item-count) mode, must be ≤ the `behind` count (asserted in debug) — a larger threshold
    /// fires inside the evictable range, loading a page that's purged before reaching the viewport.
    /// Default: 3. Captured at view identity.
    public func reachEndThreshold(_ count: Int) -> Self {
        var copy = self
        copy.reachEndThreshold = count
        return copy
    }

    /// Registers a handler invoked on `@MainActor` when the user taps a cell, receiving the item and
    /// its frame in scroll-content coordinates. The Coordinator always holds the latest closure.
    public func onTap(_ handler: @escaping @MainActor (Item, CGRect) -> Void) -> Self {
        var copy = self
        copy.onTap = handler
        return copy
    }

    /// Registers an async handler invoked on `@MainActor` when the visible trailing edge nears the end
    /// of the item list. Fires at most once per page; the gate resets when `items.count` grows. Extend
    /// the list inside this handler to implement infinite scroll.
    public func onReachEnd(_ handler: @escaping @MainActor () async -> Void) -> Self {
        var copy = self
        copy.onReachEnd = handler
        return copy
    }

    // MARK: - Coordinator

    /// Internal trampoline target managed by SwiftUI. Holds the latest closure values from the parent
    /// body so `updateUIView` can refresh them without re-wiring the UIView's stored callbacks. Created
    /// once per `FeedScrollView` instance; survives struct recreation.
    @MainActor
    public final class Coordinator {
        var cellBuilder: (@MainActor (Item) -> Cell)?
        var onTap: (@MainActor (Item, CGRect) -> Void)?
        var onReachEnd: (@MainActor () async -> Void)?

        func handleTap(_ item: Item, _ frame: CGRect) { onTap?(item, frame) }
        func handleReachEnd() async { await onReachEnd?() }
        func build(_ item: Item) -> any RenderNode {
            cellBuilder!(item).renderBody
        }
    }

    /// Creates the coordinator. Called once per `FeedScrollView` instance by SwiftUI.
    public func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - UIViewRepresentable

    public func makeUIView(context: Context) -> FeedScrollView<Item> {
        #if DEBUG
        // Only meaningful in item-count mode, where "behind" is a concrete item count to compare against.
        // Screens mode has no direct item-behind count — the trigger still fires, just without this check.
        if case .items(_, let behind) = warmWindow {
            assert(reachEndThreshold <= behind,
                   "AsyncFeed: reachEndThreshold > prefetchWindow(behind:) — page-load trigger fires inside the evictable window.")
        }
        #endif

        return buildUIView(coordinator: context.coordinator)
    }

    /// Shared body of `makeUIView(context:)`, factored out so it can be exercised without a SwiftUI
    /// `Context` (no public initializer, can't be constructed outside SwiftUI's runtime).
    private func buildUIView(coordinator: Coordinator) -> FeedScrollView<Item> {
        coordinator.cellBuilder = cellBuilder
        coordinator.onTap = onTap
        coordinator.onReachEnd = onReachEnd

        let view = FeedScrollView<Item>(
            environment: environment,
            warmWindow: warmWindow,
            reachEndThreshold: reachEndThreshold,
            layoutProvider: layout.provider
        )

        // Route through coordinator rather than capturing self (a value type) in view-stored
        // closures. Coordinator outlives each struct update, so a direct strong capture is safe.
        view.cellBuilder = { item in coordinator.build(item) }
        view.onTap = { item, frame in coordinator.handleTap(item, frame) }
        view.onReachEnd = { await coordinator.handleReachEnd() }

        return view
    }

    public func updateUIView(_ uiView: FeedScrollView<Item>, context: Context) {
        let coordinator = context.coordinator

        // Always refresh Coordinator slots — they capture current SwiftUI state.
        coordinator.cellBuilder = cellBuilder
        coordinator.onTap = onTap
        coordinator.onReachEnd = onReachEnd

        // Prefetch window is init-time only. Debug-assert values unchanged.
        #if DEBUG
        assert(uiView.warmWindow == warmWindow,
               "AsyncFeed.prefetchWindow/.prefetchScreens is init-time only — mutating it requires a .id() rebuild.")
        #endif

        guard itemsDiffer(uiView.items, items, on: uiView) else { return }

        CATransaction.begin()
        if !shouldAnimate(context: context) {
            CATransaction.setDisableActions(true)
        }
        defer { CATransaction.commit() }

        uiView.items = items
    }

    public static func dismantleUIView(_ uiView: FeedScrollView<Item>, coordinator: Coordinator) {
        uiView.cancelInFlightWork()
        let gifActor = uiView.renderEnvironment.gifActor
        let cohort = ObjectIdentifier(uiView)
        Task { await gifActor.stopDisplayLinks(cohort: cohort) }
        coordinator.cellBuilder = nil
        coordinator.onTap = nil
        coordinator.onReachEnd = nil
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: FeedScrollView<Item>,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        )
    }

    // MARK: - warmUp

    /// Warms `environment.layoutCache` and `environment.imageActor`'s image cache before first mount.
    /// Call before assigning `items`, typically inside a `Task` in the data-loading path; await the
    /// returned `Task` so both caches populate before `layoutSubviews` fires.
    ///
    /// `width`/`scale`/`contentSizeCategory`/`layout` must match what `FeedScrollView` uses at mount —
    /// a mismatch is a silent `CacheKey` miss (one gray frame, no crash). Pass a bounded head-set
    /// (first 10–20 items); there's no internal fan-out cap.
    ///
    /// Cancelling the returned `Task` stops new prefetches; in-flight decodes finish naturally.
    /// Idempotent for the same items/width/scale/layout.
    @MainActor
    public static func warmUp(
        items: [Item],
        width: CGFloat,
        scale: CGFloat,
        environment: RenderEnvironment,
        layout: GridLayout = .vertical(),
        contentSizeCategory: VContentSizeCategory = .unspecified,
        cellBuilder: @escaping @MainActor (Item) -> Cell
    ) -> Task<Void, Never> {
        guard !items.isEmpty else { return Task {} }

        // Mirror the scale floor in FeedScrollView.spawnMediaFetches — a sub-1 or zero scale would
        // produce a different ImageCacheKey than mount-time uses, so the warmUp hit never lands.
        let capturedScale = max(1, scale)
        let tables = items.map { item in
            flatten(cellBuilder(item).renderBody, itemID: item.id, contentSizeCategory: contentSizeCategory)
        }
        let cache = environment.layoutCache
        let pool = environment.textPool
        let actor = environment.imageActor
        let capturedWidth = layout.provider.measureWidth(availableWidth: width)

        return Task {
            var allFragments: [[Fragment]] = []
            allFragments.reserveCapacity(tables.count)

            await withTaskGroup(of: [Fragment].self) { group in
                for table in tables {
                    let key = CacheKey(layoutHash: table.layoutHash, width: capturedWidth)
                    group.addTask {
                        if let entry = await cache.get(key) {
                            return entry.fragments
                        }
                        guard !Task.isCancelled else { return [] }
                        let layout = await measureNode(
                            table, nodeIndex: 0,
                            width: capturedWidth,
                            textPool: pool
                        )
                        let fragments = extractFragments(table: table, layout: layout)
                        await cache.set(CellEntry(layout: layout, fragments: fragments), for: key)
                        return fragments
                    }
                }
                for await fragments in group {
                    allFragments.append(fragments)
                }
            }

            guard !Task.isCancelled else { return }

            await withTaskGroup(of: Void.self) { group in
                for fragments in allFragments {
                    for fragment in fragments {
                        guard case .image(let d) = fragment.content, let url = d.url else { continue }
                        guard !Task.isCancelled else { return }
                        let u = url
                        let s = fragment.frame.size
                        let r = d.cornerRadius
                        group.addTask {
                            // Pre-mount warm-up: nothing has scrolled yet, so these items are
                            // "coming into view next" rather than "already scrolled past".
                            await actor.prefetch(for: u, targetSize: s, cornerRadius: r, scale: capturedScale, priority: .ahead)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    // Snap policy: Phase 1 always disables CALayer animations. Phase 6+ extension hook —
    // extend here rather than adding CATransaction calls at other sites.
    private func shouldAnimate(context: Context) -> Bool { false }

    private func itemsDiffer(_ a: [Item], _ b: [Item], on uiView: FeedScrollView<Item>) -> Bool {
        // (a) Count mismatch — O(1), catches "page appended" case.
        if a.count != b.count { return true }
        // (b) Buffer identity — O(1), catches CoW-preserved arrays.
        let sameBuffer = a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in ap.baseAddress == bp.baseAddress }
        }
        if sameBuffer {
            uiView._testHooks.itemsDifferBufferHitCount += 1
            return false
        }
        // (c) Deep equality — Item: Equatable required.
        uiView._testHooks.itemsDifferDeepEqualCount += 1
        return a != b
    }

    // MARK: - Test hooks

    #if canImport(XCTest)
    /// Test-only: exercises the same coordinator-wiring path as `makeUIView(context:)` without a
    /// SwiftUI `Context` (no public initializer). Pass the same `Coordinator` across repeated calls
    /// to simulate SwiftUI re-invoking `makeUIView` for one view identity.
    func _testMakeUIView(coordinator: Coordinator) -> FeedScrollView<Item> {
        buildUIView(coordinator: coordinator)
    }

    /// Test-only: exercises `itemsDiffer` exactly as `updateUIView` does — comparing `uiView.items`
    /// against this struct's `items` — without requiring a SwiftUI `Context`.
    func _testItemsDiffer(uiView: FeedScrollView<Item>) -> Bool {
        itemsDiffer(uiView.items, items, on: uiView)
    }
    #endif
}
#endif
