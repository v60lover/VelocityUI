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
/// SwiftUI's `UIViewRepresentable.Context` has no public initializer, so these go through
/// `AsyncFeed`'s `#if canImport(XCTest)` shims (`_testMakeUIView`, `_testItemsDiffer`), which
/// delegate to the same private helpers the real `makeUIView`/`updateUIView` call — no
/// reimplementation, no drift risk. See VelocityUI-zhd design notes for the full trace.
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
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore()
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

    // MARK: - 4. tailFollow modifier surface (VelocityUI-8otc.6.5)

    /// No `.tailFollow` modifier applied — `FeedScrollView.tailFollowMode` must stay `.off`, the
    /// source-compatible default asserted by the bead's acceptance criteria.
    func testTailFollow_noModifier_defaultsToOff() {
        let feed = makeFeed()
        let coordinator = feed.makeCoordinator()
        let view = feed._testMakeUIView(coordinator: coordinator)

        XCTAssertEqual(view.tailFollowMode, .off)
    }

    /// `.tailFollow(.llmChat, pinTrigger:)` must thread `mode` all the way into the
    /// `FeedScrollView` init argument `AsyncFeed.buildUIView` passes through.
    func testTailFollow_llmChatModifier_setsFeedScrollViewTailFollowMode() {
        let feed = makeFeed().tailFollow(.llmChat, pinTrigger: 0)
        let coordinator = feed.makeCoordinator()
        let view = feed._testMakeUIView(coordinator: coordinator)

        XCTAssertEqual(view.tailFollowMode, .llmChat)
    }

    /// A `pinTrigger` value change across two `updateUIView` passes must call `pinTailSpacer()`
    /// exactly once — the once-per-user-turn contract in the bead's acceptance criteria. Uses
    /// `_testUpdateUIView`, which runs the same coordinator-refresh + pin-trigger-diff body as
    /// the real `updateUIView(_:context:)`.
    func testTailFollow_pinTriggerChange_callsPinTailSpacerExactlyOnce() {
        let seed = makeFeed().tailFollow(.llmChat, pinTrigger: 0)
        let coordinator = seed.makeCoordinator()
        let view = seed._testMakeUIView(coordinator: coordinator)

        XCTAssertEqual(view._pinTailSpacerCallCount, 0, "no pin yet at mount time")

        let updated = makeFeed().tailFollow(.llmChat, pinTrigger: 1)
        updated._testUpdateUIView(uiView: view, coordinator: coordinator)

        XCTAssertEqual(view._pinTailSpacerCallCount, 1,
            "pinTrigger changed from 0 to 1 — pinTailSpacer() must fire exactly once")
    }

    /// A repeated `updateUIView` pass with the SAME `pinTrigger` value must NOT call
    /// `pinTailSpacer()` again — otherwise every unrelated re-render (e.g. a streaming token
    /// appended to the active assistant turn) would re-pin and fight the user's own scroll.
    func testTailFollow_unchangedPinTrigger_doesNotCallPinTailSpacerAgain() {
        let seed = makeFeed().tailFollow(.llmChat, pinTrigger: 1)
        let coordinator = seed.makeCoordinator()
        let view = seed._testMakeUIView(coordinator: coordinator)

        let firstUpdate = makeFeed().tailFollow(.llmChat, pinTrigger: 1)
        firstUpdate._testUpdateUIView(uiView: view, coordinator: coordinator)
        XCTAssertEqual(view._pinTailSpacerCallCount, 0, "trigger unchanged since mount — no pin yet")

        let secondUpdate = makeFeed().tailFollow(.llmChat, pinTrigger: 1)
        secondUpdate._testUpdateUIView(uiView: view, coordinator: coordinator)

        XCTAssertEqual(view._pinTailSpacerCallCount, 0,
            "pinTrigger unchanged across repeated updateUIView passes — must not call pinTailSpacer()")
    }

    /// The pin must land on the turn the user just sent, not the previous last item. `pinTailSpacer()`
    /// reads `items.count - 1`, so it has to run AFTER `updateUIView` assigns the grown array —
    /// otherwise the pin lands on the old last item (off by the number of turns appended) and the
    /// previous assistant answer sticks to the top instead of clearing for the new message.
    func testTailFollow_pinTriggerChangeWithAppendedItems_pinsNewLastIndex() {
        let seed = makeFeed(items: [FeedTestItem(id: 0), FeedTestItem(id: 1)])
            .tailFollow(.llmChat, pinTrigger: 0)
        let coordinator = seed.makeCoordinator()
        let view = seed._testMakeUIView(coordinator: coordinator)

        // User sends a new turn: items grow from 2 to 3, pinTrigger bumps in the same update.
        let updated = makeFeed(items: [FeedTestItem(id: 0), FeedTestItem(id: 1), FeedTestItem(id: 2)])
            .tailFollow(.llmChat, pinTrigger: 1)
        updated._testUpdateUIView(uiView: view, coordinator: coordinator)

        XCTAssertEqual(view._debugTailSpacerPinIndex, 2,
            "pin must land on the freshly appended turn (index 2), not the previous last item (index 1)")
    }
}
#endif
