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

        let coordinator = context.coordinator
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

        guard itemsDiffer(uiView.items, items) else { return }

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

    // MARK: - Private helpers

    // Snap policy: Phase 1 always disables CALayer animations. Phase 6+ extension hook —
    // extend here rather than adding CATransaction calls at other sites.
    private func shouldAnimate(context: Context) -> Bool { false }

    private func itemsDiffer(_ a: [Item], _ b: [Item]) -> Bool {
        // (a) Count mismatch — O(1), catches "page appended" case.
        if a.count != b.count { return true }
        // (b) Buffer identity — O(1), catches CoW-preserved arrays.
        let sameBuffer = a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in ap.baseAddress == bp.baseAddress }
        }
        if sameBuffer { return false }
        // (c) Deep equality — Item: Equatable required.
        return a != b
    }
}
#endif
