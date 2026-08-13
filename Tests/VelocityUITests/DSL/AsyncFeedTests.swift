// AsyncFeedTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import SwiftUI
@testable import VelocityUI

// MARK: - Test fixtures

private struct FeedTestItem: Identifiable, Sendable, Equatable {
    let id: Int
}

private struct FeedTestCell: RenderView {
    let item: FeedTestItem
    var renderBody: AsyncImageNode {
        AsyncImageNode(url: nil, aspectRatio: 1.0)
    }
}

// MARK: - Tests

/// Covers three AsyncFeed invariants that don't need a host app: Coordinator-refresh closure
/// freshness, the itemsDiffer fast-path branch counters, and Coordinator identity survival
/// across simulated `makeUIView` re-calls.
///
/// SwiftUI's `UIViewRepresentable.Context` has no public initializer, so `makeUIView(context:)`
/// and `updateUIView(_:context:)` cannot be invoked directly from a unit test. All three tests
/// go through `AsyncFeed`'s `#if canImport(XCTest)` test shims (`_testMakeUIView(coordinator:)`,
/// `_testItemsDiffer(uiView:)`), which delegate to the exact same private helpers the real
/// `makeUIView`/`updateUIView` call — no reimplementation, no drift risk. See VelocityUI-zhd
/// design notes for the full trace + assertion mapping.
@MainActor
final class AsyncFeedTests: XCTestCase {

    private func makeEnvironment() -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore()
        )
    }

    private func makeFeed(items: [FeedTestItem] = []) -> AsyncFeed<FeedTestItem, FeedTestCell> {
        AsyncFeed<FeedTestItem, FeedTestCell>(
            items: items,
            environment: makeEnvironment(),
            cellBuilder: { FeedTestCell(item: $0) }
        )
    }

    // MARK: - 1. Closure-freshness regression

    /// The tap trampoline wired in `makeUIView` (`view.onTap = { coordinator.handleTap($0, $1) }`)
    /// captures the Coordinator by reference, not the closure by value. Refreshing
    /// `coordinator.onTap` after the trampoline exists (as `updateUIView` does on every call)
    /// must change what fires — without that refresh, the trampoline would still invoke the
    /// stale handler captured at `makeUIView` time.
    func testClosureFreshness_coordinatorRefresh_trampolineFiresLatestHandler() {
        let feed = makeFeed()
        let coordinator = feed.makeCoordinator()

        var firedA = false
        var firedB = false
        coordinator.onTap = { _, _ in firedA = true }

        // Real production wiring path (makeUIView's body via the test shim).
        let view = feed._testMakeUIView(coordinator: coordinator)

        // Simulate updateUIView's unconditional Coordinator-slot refresh with a new handler —
        // the regression this test guards: without the refresh, the trampoline captured above
        // would still invoke handler A.
        coordinator.onTap = { _, _ in firedB = true }

        view.onTap?(FeedTestItem(id: 1), .zero)

        XCTAssertFalse(firedA, "stale handler A must not fire — coordinator was refreshed before the trampoline fired")
        XCTAssertTrue(firedB, "refreshed handler B must fire")
    }

    // MARK: - 2. Items-guard fast-path branch counters

    /// `itemsDiffer`'s buffer-identity check (case b) must be the branch taken for a
    /// structurally-identical, CoW-preserved items array — never falling through to the O(n)
    /// `Equatable` deep-comparison fallback (case c).
    func testItemsGuardFastPath_structurallyIdenticalArray_takesBufferIdentityPath() {
        let items = (0..<5).map { FeedTestItem(id: $0) }
        let env = makeEnvironment()
        let uiView = FeedScrollView<FeedTestItem>(environment: env)
        uiView.items = items

        let feed = AsyncFeed<FeedTestItem, FeedTestCell>(
            items: items, // same value/CoW buffer as uiView.items — no mutation in between
            environment: env,
            cellBuilder: { FeedTestCell(item: $0) }
        )

        for _ in 0..<100 {
            _ = feed._testItemsDiffer(uiView: uiView)
        }

        XCTAssertEqual(uiView._itemsDiffer_bufferHitCount, 100,
            "buffer-identity fast path must be hit on every call for a CoW-identical array")
        XCTAssertEqual(uiView._itemsDiffer_deepEqualCount, 0,
            "deep-equality fallback must never run when the buffer is identical")
    }

    // MARK: - 3. Coordinator identity survival across makeUIView re-calls

    /// SwiftUI calls `makeCoordinator()` exactly once per view identity and hands the same
    /// instance back via `context.coordinator` on every subsequent `makeUIView`/`updateUIView`
    /// call for that identity — even though the `AsyncFeed` value itself is recreated on every
    /// parent `body` re-evaluation. This test simulates 10 such re-renders (a fresh `AsyncFeed`
    /// struct each time, mirroring struct recreation) while threading the SAME Coordinator
    /// through, and verifies both its identity and that it is functionally the instance actually
    /// wired into each resulting view (not merely an unchanged local variable).
    func testCoordinatorIdentity_survivesRepeatedMakeUIViewReCalls() {
        let items = [FeedTestItem(id: 1)]
        let env = makeEnvironment()

        let seedFeed = AsyncFeed<FeedTestItem, FeedTestCell>(
            items: items, environment: env, cellBuilder: { FeedTestCell(item: $0) }
        )
        let coordinator = seedFeed.makeCoordinator()
        let originalID = ObjectIdentifier(coordinator)

        for i in 0..<10 {
            // New AsyncFeed struct value each iteration — mirrors SwiftUI recreating the View
            // struct on every parent body re-evaluation. Passing the SAME coordinator mirrors
            // context.coordinator, which SwiftUI holds stable for this view identity.
            let recreated = AsyncFeed<FeedTestItem, FeedTestCell>(
                items: items, environment: env, cellBuilder: { FeedTestCell(item: $0) }
            )
            let view = recreated._testMakeUIView(coordinator: coordinator)

            XCTAssertEqual(ObjectIdentifier(coordinator), originalID,
                "Coordinator identity changed on re-call #\(i)")

            var fired = false
            coordinator.onTap = { _, _ in fired = true }
            view.onTap?(FeedTestItem(id: 1), .zero)
            XCTAssertTrue(fired, "view #\(i)'s trampoline must route through the shared coordinator instance")
        }
    }
}
#endif
