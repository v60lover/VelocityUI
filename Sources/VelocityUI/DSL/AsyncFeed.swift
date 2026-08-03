// AsyncFeed.swift

#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI entry point for VelocityUI feeds.
///
/// AsyncFeed deliberately does NOT conform to Equatable.
///
/// The .equatable() skip path would mask closure-modifier changes:
/// .onTap / .onReachEnd capture SwiftUI state but cannot participate in ==
/// (closures are not Equatable). A skipped updateUIView leaves Coordinator
/// slots stale, silently dropping the consumer's latest closure for one or
/// more update cycles. The structural guard inside updateUIView makes the
/// common "items unchanged" case cheap enough that the skip is not worth
/// the staleness hazard.
@MainActor
public struct AsyncFeed<
    Item: Identifiable & Sendable & Equatable,
    Cell: RenderView
>: UIViewRepresentable where Item.ID: Sendable {

    // MARK: - Stored properties (value-type copies for modifier chaining)

    private let items: [Item]
    private let environment: RenderEnvironment
    private let cellBuilder: @MainActor (Item) -> Cell
    private var prefetchAhead: Int = 10
    private var prefetchBehind: Int = 3
    private var reachEndThreshold: Int = 3
    private var onTap: (@MainActor (Item, CGRect) -> Void)? = nil
    private var onReachEnd: (@MainActor () async -> Void)? = nil

    // MARK: - Init

    /// Creates a feed backed by the given items.
    ///
    /// - Parameters:
    ///   - items: Ordered sequence of items to display. Updated on every parent body call;
    ///     unchanged arrays skip rebuild via identity + equality guards in `updateUIView`.
    ///   - environment: Composition root. Construct once (e.g. `@State`) and reuse across
    ///     re-renders so `LayoutCache` and `DimensionCache` survive SwiftUI identity changes.
    ///   - cellBuilder: Called on `@MainActor` to produce the DSL node tree for each item.
    ///     Evaluated once per item change; the result is flattened to a `NodeTable` immediately
    ///     and the existential does not escape Layer 1.
    public init(
        items: [Item],
        environment: RenderEnvironment,
        cellBuilder: @escaping @MainActor (Item) -> Cell
    ) {
        self.items = items
        self.environment = environment
        self.cellBuilder = cellBuilder
    }

    // MARK: - Modifiers

    /// Sets the number of items to keep warm outside the visible area.
    ///
    /// Captured at view identity. Changing the values after mount has no effect
    /// (debug builds assert; release builds silently ignore). Force a `.id()` rebuild to
    /// change the prefetch window at runtime.
    ///
    /// - Parameters:
    ///   - ahead: Items to prefetch ahead of the visible leading edge. Default: 10.
    ///   - behind: Items to keep warm behind the visible trailing edge. Default: 3.
    public func prefetchWindow(ahead: Int, behind: Int) -> Self {
        var copy = self
        copy.prefetchAhead = ahead
        copy.prefetchBehind = behind
        return copy
    }

    /// Sets how many items from the end of the list trigger `onReachEnd`.
    ///
    /// Must be ≤ `prefetchBehind` (asserted in debug builds) — a threshold larger than the
    /// behind-window fires inside the evictable range, potentially loading a page that is
    /// immediately purged before reaching the visible viewport.
    ///
    /// Default: 3. Captured at view identity (same rules as `prefetchWindow`).
    public func reachEndThreshold(_ count: Int) -> Self {
        var copy = self
        copy.reachEndThreshold = count
        return copy
    }

    /// Registers a handler invoked on `@MainActor` when the user taps a cell.
    ///
    /// The handler receives the tapped item and its frame in scroll-content coordinates.
    /// The Coordinator always holds the latest closure — no staleness window regardless
    /// of SwiftUI update batching.
    public func onTap(_ handler: @escaping @MainActor (Item, CGRect) -> Void) -> Self {
        var copy = self
        copy.onTap = handler
        return copy
    }

    /// Registers an async handler invoked on `@MainActor` when the visible trailing edge
    /// nears the end of the item list.
    ///
    /// Fires at most once per page; the gate resets when `items.count` grows. Extend the
    /// list inside this handler to implement infinite scroll. The Coordinator always holds
    /// the latest closure — no staleness window regardless of SwiftUI update batching.
    public func onReachEnd(_ handler: @escaping @MainActor () async -> Void) -> Self {
        var copy = self
        copy.onReachEnd = handler
        return copy
    }

    // MARK: - Coordinator

    /// Internal trampoline target managed by SwiftUI. Do not interact directly.
    ///
    /// Holds the latest closure values from the parent body so `updateUIView` can refresh
    /// them without re-wiring the UIView's stored callbacks on every struct recreation.
    /// Created once per `FeedScrollView` instance; survives struct recreation; torn down
    /// with the UIView on `.id()` changes.
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
        assert(reachEndThreshold <= prefetchBehind,
               "AsyncFeed: reachEndThreshold > prefetchBehind — page-load trigger fires inside the evictable window.")
        #endif

        return buildUIView(coordinator: context.coordinator)
    }

    /// Shared body of `makeUIView(context:)`, factored out so it can be exercised without a
    /// SwiftUI `Context` (which has no public initializer and cannot be constructed outside
    /// SwiftUI's own runtime — see `_testMakeUIView(coordinator:)`).
    private func buildUIView(coordinator: Coordinator) -> FeedScrollView<Item> {
        coordinator.cellBuilder = cellBuilder
        coordinator.onTap = onTap
        coordinator.onReachEnd = onReachEnd

        let view = FeedScrollView<Item>(
            environment: environment,
            prefetchAheadCount: prefetchAhead,
            prefetchBehindCount: prefetchBehind,
            reachEndThreshold: reachEndThreshold
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
        assert(uiView.prefetchAheadCount == prefetchAhead,
               "AsyncFeed.prefetchWindow(ahead:) is init-time only — mutating it requires a .id() rebuild.")
        assert(uiView.prefetchBehindCount == prefetchBehind,
               "AsyncFeed.prefetchWindow(behind:) is init-time only — mutating it requires a .id() rebuild.")
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

    /// Warms the image and layout caches for the given items before first mount.
    ///
    /// Call before assigning `items` to `AsyncFeed` — typically inside a `Task` in the
    /// view's data-loading path. Await the returned `Task` to ensure both caches are
    /// populated before the view hierarchy is built and `layoutSubviews` fires.
    ///
    /// Contract: `width` and `scale` must match what `FeedScrollView` will use at mount
    /// time. A mismatch on either dimension produces `CacheKey` misses and silently falls
    /// back to the standard pipeline path — no crash, just one gray frame.
    /// Pass a bounded head-set (typically the first 10–20 items); warmUp has no internal
    /// fan-out cap and will decode every item's images regardless of list length.
    ///
    /// Side effects:
    /// - Populates `environment.layoutCache` with a `CellEntry` for each item.
    /// - Populates `environment.imageActor`'s image cache with decoded images for all
    ///   image fragments at the fragment-computed target sizes.
    ///
    /// Cancellation: cancelling the returned `Task` stops new prefetches from being
    /// issued. In-flight decode tasks inside `ImageActor` complete naturally.
    ///
    /// Idempotent: a second call for the same items, width, and scale hits
    /// `LayoutCache` and `ImageActor`'s cache immediately and returns fast.
    @MainActor
    public static func warmUp(
        items: [Item],
        width: CGFloat,
        scale: CGFloat,
        environment: RenderEnvironment,
        cellBuilder: @escaping @MainActor (Item) -> Cell
    ) -> Task<Void, Never> {
        guard !items.isEmpty else { return Task {} }

        // Mirror the scale floor in FeedScrollView.spawnMediaFetches: a sub-1 or zero
        // scale produces a different ImageCacheKey than the one mount-time uses, so the
        // warmUp hit never lands. Floor to 1 matches the mount-path floor exactly.
        let capturedScale = max(1, scale)
        let tables = items.map { item in flatten(cellBuilder(item).renderBody, itemID: item.id) }
        let cache = environment.layoutCache
        let pool = environment.textPool
        let actor = environment.imageActor
        let capturedWidth = width

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
                            await actor.prefetch(for: u, targetSize: s, cornerRadius: r, scale: capturedScale)
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
            #if canImport(XCTest)
            uiView._itemsDiffer_bufferHitCount += 1
            #endif
            return false
        }
        // (c) Deep equality — Item: Equatable required.
        #if canImport(XCTest)
        uiView._itemsDiffer_deepEqualCount += 1
        #endif
        return a != b
    }

    // MARK: - Test hooks

    #if canImport(XCTest)
    /// Test-only: exercises the same coordinator-wiring path as `makeUIView(context:)` without
    /// requiring a SwiftUI `Context` (no public initializer; cannot be constructed in a unit
    /// test host). Callers pass the same `Coordinator` instance across repeated calls to
    /// simulate SwiftUI re-invoking `makeUIView` for one view identity — SwiftUI always supplies
    /// the same coordinator via `context.coordinator` for the lifetime of that identity.
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
