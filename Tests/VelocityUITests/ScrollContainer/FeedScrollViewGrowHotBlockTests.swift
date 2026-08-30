// FeedScrollViewGrowHotBlockTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers VelocityUI-80uh (B1): `FeedScrollView.growHotBlock(_:)`, the explicit hot-block
/// side-channel a streaming caller invokes INSTEAD OF reassigning `items` while a scroll
/// gesture is active. Built directly on top of the same `applyInPlaceBlockDiff` primitive
/// `FeedScrollViewBlockDiffTests` (VelocityUI-x4q0) already covers — these tests focus on the
/// NEW eligibility gate and on the "scoped to one item, nothing to reconcile at gesture end"
/// properties that are specific to `growHotBlock`, reusing the same `ChatItem` fixture shape.
@MainActor
final class FeedScrollViewGrowHotBlockTests: XCTestCase {

    struct ChatItem: Identifiable, Sendable {
        let id: Int
        let blocks: [String]
    }

    final class Counter { var value = 0 }

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

    private func makeChatFeed(
        environment: RenderEnvironment? = nil,
        cellBuilderCounter: Counter? = nil
    ) -> FeedScrollView<ChatItem> {
        let env = environment ?? makeEnvironment()
        let feed = FeedScrollView<ChatItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            cellBuilderCounter?.value += 1
            return VStackNode(spacing: 4) {
                for text in item.blocks {
                    TextNode(text)
                }
            }
        }
        return feed
    }

    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<ChatItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    // MARK: - Eligibility gate

    func testNotGestureActive_Declines() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        feed._debugGestureActiveOverride = false
        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1

        let handled = feed.growHotBlock(ChatItem(id: 0, blocks: ["seed grew"]))

        XCTAssertFalse(handled, "growHotBlock must decline when no gesture is active")
        XCTAssertEqual(feed._debugResolvedFrame(at: 0)?.height, heightBefore,
            "a declined call must not touch layout")
        XCTAssertEqual(feed._growHotBlockSuccessCount, 0)

        await drainFeedWork(feed)
    }

    func testNotLastItem_Declines() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["first"]), ChatItem(id: 1, blocks: ["second"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        await waitForWorkingRangeCommit(feed, index: 1)

        feed._debugGestureActiveOverride = true
        let handled = feed.growHotBlock(ChatItem(id: 0, blocks: ["first grew"]))

        XCTAssertFalse(handled, "growHotBlock must decline for anything but the LAST item — "
            + "above-viewport/multi-message growth (VelocityUI-qgy9) is out of scope")

        await drainFeedWork(feed)
    }

    func testCellNotMounted_Declines() async {
        let feed = makeChatFeed()
        // Mount many items so the LAST item is nowhere near the top viewport and never gets a cell.
        feed.items = (0..<200).map { ChatItem(id: $0, blocks: ["seed \($0)"]) }
        feed.layoutSubviews()

        feed._debugGestureActiveOverride = true
        let handled = feed.growHotBlock(ChatItem(id: 199, blocks: ["seed 199 grew"]))

        XCTAssertFalse(handled, "growHotBlock must decline when the item's cell isn't mounted")

        await drainFeedWork(feed)
    }

    func testWorkingRangeNotPrimed_DeclinesRightAfterInvalidation() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Adding an item invalidates WorkingRange wholesale (needsFullInvalidation, add != empty).
        // Deliberately no layoutSubviews() here — WorkingRange stays wiped for the new index 1.
        feed.items = [ChatItem(id: 0, blocks: ["seed"]), ChatItem(id: 1, blocks: ["new last item"])]

        feed._debugGestureActiveOverride = true
        let handled = feed.growHotBlock(ChatItem(id: 1, blocks: ["new last item grew"]))

        XCTAssertFalse(handled, "growHotBlock must decline while WorkingRange isn't primed for this index yet")

        await drainFeedWork(feed)
    }

    // MARK: - Success path: pure append, scoped to one item

    func testGestureActive_PureAppend_GrowsImmediatelyWithoutFullPass() async {
        let counter = Counter()
        let feed = makeChatFeed(cellBuilderCounter: counter)
        // Small enough that every item lands inside the default prefetch window at the initial
        // scroll position (no scrolling needed) — a larger count would leave the LAST item
        // outside WorkingRange/mounted-cell range, which is a different, already-covered
        // scenario (testCellNotMounted_Declines / testWorkingRangeNotPrimed_...).
        let itemCount = 5
        feed.items = (0..<itemCount).map { ChatItem(id: $0, blocks: ["seed \($0)"]) }
        feed.layoutSubviews()
        for i in 0..<itemCount { await waitForWorkingRangeCommit(feed, index: i) }

        let lastID = itemCount - 1
        let heightBefore = feed._debugResolvedFrame(at: lastID)?.height ?? -1
        XCTAssertGreaterThan(heightBefore, 0, "Precondition: last item must have a real measured height")

        counter.value = 0
        let taskSpawnBefore = feed._taskSpawnCount
        feed._debugGestureActiveOverride = true

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let handled = feed.growHotBlock(ChatItem(id: lastID, blocks: [longText]))

        XCTAssertTrue(handled, "growHotBlock must succeed for a pure append to the last item's block")
        XCTAssertEqual(feed._growHotBlockSuccessCount, 1)
        XCTAssertEqual(counter.value, 1,
            "growHotBlock must flatten ONLY the grown item — not all \(itemCount) items in the feed")
        XCTAssertEqual(feed._taskSpawnCount, taskSpawnBefore,
            "growHotBlock must never spawn a pipeline notify Task — it never touches the leading index")

        let heightAfter = feed._debugResolvedFrame(at: lastID)?.height ?? -1
        XCTAssertGreaterThan(heightAfter, heightBefore,
            "the new (longer) content's height must be reflected IMMEDIATELY — no layoutSubviews() call needed")

        XCTAssertEqual(feed._workingRangeMissCount(from: lastID, to: lastID + 1), 0,
            "WorkingRange for the grown item must be kept committed, never invalidated, by growHotBlock")

        await drainFeedWork(feed)
    }

    func testGestureActive_ContentSizeGrowsBySameDelta() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height
        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1

        feed._debugGestureActiveOverride = true
        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])))

        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        let delta = heightAfter - heightBefore
        XCTAssertGreaterThan(delta, 0)
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "contentSize must grow by exactly the same delta the item's own height grew by")

        await drainFeedWork(feed)
    }

    // MARK: - Block-boundary events: handled live (not deferred) via the same general block diff

    /// `applyInPlaceBlockDiff` diffs the item's WHOLE block list on every call (not just the
    /// trailing block) — a new block appearing is a normal, already-supported shape for it
    /// (`diff(previous:new:frontier:)`'s `sealedChanged`/`volatile` classification), so
    /// `growHotBlock` does NOT need to detect or defer boundary events: they are applied live,
    /// during the gesture, exactly like a pure append. This is a stronger result than the bead's
    /// own design sketch assumed (deferred-to-idle) — verified empirically here rather than
    /// taken on faith, since it changes what `growHotBlock`'s doc comment can honestly promise.
    func testBlockBoundary_NewBlockAppearsMidGesture_HandledLiveNotDeferred() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["block zero content"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        feed._debugGestureActiveOverride = true

        // A NEW block (a "paragraph boundary" in the flagship's markdown terms) appears.
        let handled = feed.growHotBlock(ChatItem(id: 0, blocks: ["block zero content", "block one starts"]))

        XCTAssertTrue(handled, "a new block appearing must be handled live by the same general "
            + "block diff growHotBlock already runs — not declined")

        let painted = feed._debugPaintedBitmaps(at: 0)
        XCTAssertEqual(painted.count, 2, "both blocks must be painting real content immediately, mid-gesture")

        await drainFeedWork(feed)
    }

    // MARK: - Gesture-end reconcile is free (no re-measure/re-rasterize, no height flash)

    func testGestureEnd_ReconcileReusesAlreadyMeasuredState_NoExtraMeasureOrRasterize() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        feed._debugGestureActiveOverride = true
        var accumulated = "seed"
        var messages = [ChatItem(id: 0, blocks: [accumulated])]
        for i in 0..<5 {
            accumulated += " tok\(i)"
            let grown = ChatItem(id: 0, blocks: [accumulated])
            XCTAssertTrue(feed.growHotBlock(grown), "each pure-append token during the gesture must succeed")
            messages = [grown]
        }

        let heightDuringGesture = feed._debugResolvedFrame(at: 0)?.height ?? -1
        // `_debugPaintedBitmaps` is keyed by `Fragment.id` (== NodeTable nodeIndex, positional
        // within the flattened tree — NOT the block's position, which `BlockKey.index` uses), so
        // this reads `.values.first` rather than assuming a specific id (mirrors
        // FeedScrollViewBlockDiffTests' `paintedAfterRound1.values.contains` pattern).
        XCTAssertEqual(feed._debugPaintedBitmaps(at: 0).count, 1, "single-block item must paint exactly one bitmap")
        XCTAssertNotNil(feed._debugPaintedBitmaps(at: 0).values.first)

        let measureBefore = feed._blockDiffMeasureCallCount
        let rasterizeBefore = feed._blockDiffRasterizeCallCount

        // Gesture ends -> caller does the ONE normal `items =` reconcile assignment.
        feed._debugGestureActiveOverride = false
        feed.items = messages
        feed.layoutSubviews()

        XCTAssertEqual(feed._blockDiffMeasureCallCount, measureBefore,
            "the reconcile pass must not re-measure via the O(block) full-measure path — "
            + "HotBlockRasterizerStore already holds the final content incrementally")
        XCTAssertEqual(feed._blockDiffRasterizeCallCount, rasterizeBefore,
            "the reconcile pass must not re-rasterize from scratch via the O(block) full-rasterize path")

        let heightAfterReconcile = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertEqual(heightAfterReconcile, heightDuringGesture, accuracy: 0.01,
            "reconcile must not shift the height that was already visible during the gesture — no flash")

        await drainFeedWork(feed)
    }

    // MARK: - VelocityUI-ylux (B2): defer contentSize growth during an edge bounce

    /// While the scroll sits in a TOP edge rubber-band, a streamed grow must still PAINT (the cell
    /// layer + resolvedFrames grow, tokens fill the opened gap live) but must NOT write
    /// contentSize.height — mutating it mid-bounce moves the animation target and jumps the
    /// viewport. The withheld growth is accumulated and committed in one write once the bounce
    /// settles (the scroll leaves the bounce region). The BOTTOM edge is the opposite case, covered
    /// by `testBottomBounceRegion_WritesContentSizeImmediately_FillsTheGap`.
    func testTopBounceRegion_PaintsButDefersContentSizeWrite_ThenFlushesOnLeave() async throws {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height
        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightBefore, 0, "Precondition: last item must have a real measured height")
        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0, "Precondition: nothing deferred yet")

        feed._debugGestureActiveOverride = true
        feed._debugBounceRegionOverride = true      // simulate an active edge over-pull
        feed._debugTopBounceRegionOverride = true   // ...specifically at the TOP, where growth defers

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])),
            "the side-channel must still paint during an edge bounce (variant B: paint stays on)")

        // PAINT happened: resolvedFrames and the cell layer both grew by the same delta.
        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        let delta = heightAfter - heightBefore
        XCTAssertGreaterThan(delta, 0, "the grown tail must be reflected in resolvedFrames immediately")
        let cellLayerHeight = try XCTUnwrap(feed._cellLayer(at: 0)?.frame.height)
        XCTAssertEqual(cellLayerHeight, heightAfter, accuracy: 0.01,
            "the cell layer must grow with the painted tail even inside the bounce region")

        // RESIZE deferred: contentSize.height was NOT written during the pull; the growth is held.
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore, accuracy: 0.01,
            "contentSize.height must not be written while the edge bounce is active — that is the jump")
        XCTAssertEqual(feed._debugDeferredContentSizeDelta, delta, accuracy: 0.01,
            "the withheld growth must be accumulated, not dropped")

        // Bounce settles -> leave the region -> one flush lands the authoritative height.
        feed._debugBounceRegionOverride = false
        feed._debugTopBounceRegionOverride = false
        feed.layoutSubviews()

        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0, accuracy: 0.01,
            "the accumulator must be cleared once the deferred delta is committed")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "on leaving the bounce region the deferred delta commits in one write — "
            + "contentSize.height now equals the authoritative content height from resolvedFrames")

        await drainFeedWork(feed)
    }

    /// The user-facing fix: at the BOTTOM edge, following a live generation, a streamed grow must
    /// write contentSize.height IMMEDIATELY — never defer. The user has over-pulled below the tail
    /// into empty space; growing the height there fills that gap with the incoming text, so the
    /// scroll settles smoothly into real content instead of rubber-banding back up to a frozen edge
    /// (the "bounces up" symptom). Nothing is accumulated in the deferral channel.
    func testBottomBounceRegion_WritesContentSizeImmediately_FillsTheGap() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height
        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1

        feed._debugGestureActiveOverride = true
        feed._debugBounceRegionOverride = true       // over-pulled at an edge...
        feed._debugTopBounceRegionOverride = false   // ...the BOTTOM, not the top

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])))

        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        let delta = heightAfter - heightBefore
        XCTAssertGreaterThan(delta, 0, "the grown tail must be reflected in resolvedFrames")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "at the bottom edge contentSize must grow immediately so the over-scrolled gap fills — "
            + "this is what replaces the bounce-back-up with a smooth fill")
        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0,
            "a bottom over-pull must not defer growth — nothing may sit in the deferral channel")

        await drainFeedWork(feed)
    }

    /// The gate must be false everywhere except an actual edge over-pull: with no bounce, a
    /// streamed grow writes contentSize.height immediately (current behavior) and never touches
    /// the deferral accumulator. Guards the common mid-content-streaming path against regression.
    func testNotInBounceRegion_WritesContentSizeImmediately_NoDeferral() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height
        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1

        feed._debugGestureActiveOverride = true
        feed._debugBounceRegionOverride = false   // explicitly not in an edge over-pull

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])))

        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        let delta = heightAfter - heightBefore
        XCTAssertGreaterThan(delta, 0)
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "outside the bounce region contentSize must grow immediately by the item's delta")
        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0,
            "nothing may be accumulated when not in the bounce region")

        await drainFeedWork(feed)
    }

    /// Regression for the stranded-flush bug: a rubber-band can settle EXACTLY at the frozen edge,
    /// so `isInBounceRegion` never flips false, yet the scroll IS at rest. Gating the flush only on
    /// leaving the region strands the deferred growth — contentSize stays frozen, the bottom is
    /// unreachable, and the only motion that revives layout is scrolling up (the reported symptom).
    /// The at-rest branch must commit it the moment the scroll comes to rest.
    func testBounceRegion_StrandedAtFrozenEdge_FlushesWhenScrollComesToRest() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height

        feed._debugGestureActiveOverride = true
        feed._debugBounceRegionOverride = true      // over-pulled at the edge...
        feed._debugTopBounceRegionOverride = true   // ...the TOP, where growth defers
        feed._debugScrollAtRestOverride = false     // finger down / bounce still animating

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])))

        let delta = feed._debugDeferredContentSizeDelta
        XCTAssertGreaterThan(delta, 0, "the growth must be deferred while the bounce is active")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore, accuracy: 0.01,
            "contentSize stays frozen during the pull")

        // The bounce settles AT the frozen edge: still flagged in-bounce (rounding), but at rest.
        // A layout pass must now commit the stranded delta rather than wait for a manual scroll.
        feed._debugScrollAtRestOverride = true
        feed.layoutSubviews()

        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0, accuracy: 0.01,
            "coming to rest must flush the deferred growth even while still flagged in-bounce")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "contentSize must catch up to the real content height once the scroll rests — "
            + "not stay frozen until the user scrolls up")

        await drainFeedWork(feed)
    }

    /// The settle delegate hook (`scrollViewDidEndDecelerating`) must commit the deferred growth in
    /// one shot when a bounce ends — the reliable signal that does not depend on a streamed token
    /// arriving to drive a layout pass, and (unlike a per-frame `setNeedsLayout` pump) does not
    /// starve the deceleration and hang the edge.
    func testScrollSettleDelegate_FlushesDeferredGrowthWithoutLayoutPump() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let contentSizeBefore = feed.contentSize.height
        feed._debugGestureActiveOverride = true
        feed._debugBounceRegionOverride = true
        feed._debugTopBounceRegionOverride = true   // TOP over-pull: growth defers

        let longText = (0..<40).map { "word\($0)" }.joined(separator: " ")
        XCTAssertTrue(feed.growHotBlock(ChatItem(id: 0, blocks: [longText])))
        let delta = feed._debugDeferredContentSizeDelta
        XCTAssertGreaterThan(delta, 0, "growth must be deferred during the bounce")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore, accuracy: 0.01)

        // Bounce ends -> UIKit calls the settle delegate. It must flush in one shot, no layout pump.
        feed.scrollViewDidEndDecelerating(feed)

        XCTAssertEqual(feed._debugDeferredContentSizeDelta, 0, accuracy: 0.01,
            "the settle delegate must commit the deferred growth")
        XCTAssertEqual(feed.contentSize.height, contentSizeBefore + delta, accuracy: 0.01,
            "contentSize must catch up to the real content height on settle")

        await drainFeedWork(feed)
    }
}
#endif
