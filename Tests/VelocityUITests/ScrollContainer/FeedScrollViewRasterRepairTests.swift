// FeedScrollViewRasterRepairTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

struct ChatItem: Identifiable, Sendable {
    let id: Int
    let text: String
}

@MainActor
final class FeedScrollViewRasterRepairTests: XCTestCase {

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

    private func makeFeed(environment: RenderEnvironment, items: [ChatItem]) -> FeedScrollView<ChatItem> {
        let feed = FeedScrollView<ChatItem>(environment: environment, frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        feed.items = items
        feed.cellBuilder = { item in TextNode(item.text) }
        return feed
    }

    /// Polls until WorkingRange has a real committed entry at `index` (async pipeline commits off
    /// MainActor), same pattern as other FeedScrollView test files use.
    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<ChatItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTFail("Timeout waiting for WorkingRange commit at index \(index)")
    }

    /// Polls until a specific fragment bitmap is painted at a given item index.
    private func waitForBitmapPaint(
        _ feed: FeedScrollView<ChatItem>,
        at itemIndex: Int,
        fragmentId: Int = 0,
        seconds: Double = 10
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let painted = feed._debugPaintedBitmaps(at: itemIndex)
            if painted[fragmentId] != nil { return }
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTFail("Timeout waiting for bitmap to paint at item \(itemIndex), fragment \(fragmentId)")
    }

    /// Polls until all pending raster repairs have completed.
    private func waitForRepairCompletion(
        _ feed: FeedScrollView<ChatItem>,
        seconds: Double = 10
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._pendingRasterRepairIndicesCount == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTFail("Timeout waiting for repair to complete (pending count: \(feed._pendingRasterRepairIndicesCount))")
    }

    // MARK: - Diagnostic (temporary)

    func testDiagnosticFragmentState() async {
        let env = makeEnvironment()
        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(ChatItem(id: i, text: "item \(i)"))
        }
        let feed = makeFeed(environment: env, items: items)
        let key0 = BlockKey(itemID: 0, index: 0)

        feed.layoutSubviews()
        print("DIAG t=0 pending=\(feed._pendingFragmentIndicesCount) wrMiss=\(feed._workingRangeMissCount(from: 0, to: 1)) frozen=\(env.frozenBitmapStore.bitmap(for: key0) != nil) visible=\(env.visibleBlockStore.bitmap(for: key0) != nil) painted=\(feed._debugPaintedBitmaps(at: 0)[0] != nil)")

        var n = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            await Task.yield()
            feed.layoutSubviews()
            n += 1
            if n <= 40 || feed._debugPaintedBitmaps(at: 0)[0] != nil {
                print("DIAG t=\(n) pending=\(feed._pendingFragmentIndicesCount) wrMiss=\(feed._workingRangeMissCount(from: 0, to: 1)) frozen=\(env.frozenBitmapStore.bitmap(for: key0) != nil) visible=\(env.visibleBlockStore.bitmap(for: key0) != nil) painted=\(feed._debugPaintedBitmaps(at: 0)[0] != nil)")
            }
            if feed._debugPaintedBitmaps(at: 0)[0] != nil { break }
        }
    }

    // MARK: - Test 1: Core repro — eviction from both stores is repaired and repainted

    func testEvictionFromBothStoresIsRepaired() async {
        let env = makeEnvironment()
        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(ChatItem(id: i, text: "item \(i)"))
        }
        let feed = makeFeed(environment: env, items: items)

        // Step 1-2: Mount and wait for WorkingRange commit at index 0
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Step 3: Poll until bitmap paints
        await waitForBitmapPaint(feed, at: 0, fragmentId: 0)

        // Verify precondition: bitmap is actually painted before we break it
        let bitmapsBefore = feed._debugPaintedBitmaps(at: 0)
        XCTAssertNotNil(bitmapsBefore[0], "Precondition: bitmap at fragment 0 should be painted before eviction")

        // Step 4: Scroll deep to recycle cell 0 and demote its bitmap from VisibleBlockStore
        feed.contentOffset = CGPoint(x: 0, y: 1000)
        feed.layoutSubviews()

        // Step 5: Evict from both stores and verify precondition — the failure mode this
        // bead fixes: a valid WorkingRange entry with the raster gone from both bitmap stores.
        let key0 = BlockKey(itemID: 0, index: 0)
        env.visibleBlockStore.evict([key0])
        env.frozenBitmapStore.evict([key0])

        // Precondition check: both stores should now be empty for this key
        XCTAssertNil(
            env.visibleBlockStore.bitmap(for: key0),
            "Precondition: visibleBlockStore should not have bitmap after eviction"
        )
        XCTAssertNil(
            env.frozenBitmapStore.bitmap(for: key0),
            "Precondition: frozenBitmapStore should not have bitmap after eviction"
        )

        // Step 6: Scroll back to top to remount cell 0
        feed.contentOffset = CGPoint(x: 0, y: 0)
        feed.layoutSubviews()

        // Step 6: Assert detection happened inline and synchronously
        XCTAssertGreaterThanOrEqual(
            feed._pendingRasterRepairIndicesCount,
            1,
            "Missing raster should be detected inline during mount (buildSyncMap detects missingRaster)"
        )

        // Step 7: Assert fragment still blank (repair hasn't happened yet)
        let bitmapsAfterDetection = feed._debugPaintedBitmaps(at: 0)
        XCTAssertNil(
            bitmapsAfterDetection[0],
            "Fragment should still be blank after detection (repair is async, not inline)"
        )

        // Step 8: Poll until bitmap paints again (repair task rasterizes and stores it)
        await waitForBitmapPaint(feed, at: 0, fragmentId: 0)

        // Step 9: Assert repair marker cleared
        XCTAssertEqual(
            feed._pendingRasterRepairIndicesCount,
            0,
            "Repair indices should be cleared after bitmap is painted and setNeedsLayout() was called"
        )

        // Final confirmation: bitmap is definitely painted
        let bitmapsAfterRepair = feed._debugPaintedBitmaps(at: 0)
        XCTAssertNotNil(
            bitmapsAfterRepair[0],
            "Bitmap must be painted after repair completes"
        )
    }

    // MARK: - Test 2: Coalescing — multiple layout passes while repair is in flight spawn only one task

    func testMultipleLayoutPassesWhileRepairInFlightSpawnOnlyOneTask() async {
        let env = makeEnvironment()
        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(ChatItem(id: i, text: "item \(i)"))
        }
        let feed = makeFeed(environment: env, items: items)

        // Setup: Mount and wait for initial paint at index 0
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        await waitForBitmapPaint(feed, at: 0, fragmentId: 0)

        // Scroll deep to recycle cell 0
        feed.contentOffset = CGPoint(x: 0, y: 1000)
        feed.layoutSubviews()

        // Evict from both stores
        let key0 = BlockKey(itemID: 0, index: 0)
        env.visibleBlockStore.evict([key0])
        env.frozenBitmapStore.evict([key0])

        // Verify both stores are empty
        XCTAssertNil(env.visibleBlockStore.bitmap(for: key0))
        XCTAssertNil(env.frozenBitmapStore.bitmap(for: key0))

        // Scroll back to trigger detection
        feed.contentOffset = CGPoint(x: 0, y: 0)
        feed.layoutSubviews()

        // First detection should trigger spawn
        XCTAssertGreaterThanOrEqual(
            feed._pendingRasterRepairIndicesCount,
            1,
            "Detection should mark index as pending repair"
        )
        let spawnCountAfterFirstDetection = feed._repairTaskSpawnCount

        // Multiple immediate layout passes should NOT spawn more tasks
        // (they should be no-ops because _repairTask is already in flight)
        feed.layoutSubviews()
        XCTAssertEqual(
            feed._repairTaskSpawnCount,
            spawnCountAfterFirstDetection,
            "Second layout pass should not spawn a new repair task (coalescing)"
        )

        feed.layoutSubviews()
        XCTAssertEqual(
            feed._repairTaskSpawnCount,
            spawnCountAfterFirstDetection,
            "Third layout pass should not spawn a new repair task (coalescing)"
        )

        // Wait for repair to complete
        await waitForRepairCompletion(feed)
        await waitForBitmapPaint(feed, at: 0, fragmentId: 0)

        // Verify repair task count stayed the same throughout
        XCTAssertEqual(
            feed._repairTaskSpawnCount,
            spawnCountAfterFirstDetection,
            "Only one repair task should have spawned total"
        )

        // Verify painted
        let bitmapsAfterRepair = feed._debugPaintedBitmaps(at: 0)
        XCTAssertNotNil(
            bitmapsAfterRepair[0],
            "Bitmap should be painted after repair completes"
        )
    }

    // MARK: - Test 3: Repair works for multiple items independently

    func testRepairWorksForMultipleItemsIndependently() async {
        let env = makeEnvironment()
        var items: [ChatItem] = []
        for i in 0..<30 {
            items.append(ChatItem(id: i, text: "item \(i)"))
        }
        let feed = makeFeed(environment: env, items: items)

        // Setup: Mount and wait for item 5 to be committed
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 5)
        await waitForBitmapPaint(feed, at: 5, fragmentId: 0)

        // Verify precondition: bitmap is painted at item 5
        let bitmapsAtItem5Before = feed._debugPaintedBitmaps(at: 5)
        XCTAssertNotNil(
            bitmapsAtItem5Before[0],
            "Precondition: bitmap at item 5 should be painted before eviction"
        )

        // Scroll deep past item 5 to recycle it
        feed.contentOffset = CGPoint(x: 0, y: 1500)
        feed.layoutSubviews()

        // Evict item 5's block from both stores
        let key5 = BlockKey(itemID: 5, index: 0)
        env.visibleBlockStore.evict([key5])
        env.frozenBitmapStore.evict([key5])

        // Verify precondition: both stores empty for key5
        XCTAssertNil(
            env.visibleBlockStore.bitmap(for: key5),
            "Precondition: visibleBlockStore should be empty for key5"
        )
        XCTAssertNil(
            env.frozenBitmapStore.bitmap(for: key5),
            "Precondition: frozenBitmapStore should be empty for key5"
        )

        // Scroll back to the top so item 5 re-enters the warm window (it sits well within
        // the first screen's worth of short rows) and remounts.
        feed.contentOffset = CGPoint(x: 0, y: 0)
        feed.layoutSubviews()

        // Detection should happen for item 5
        XCTAssertGreaterThanOrEqual(
            feed._pendingRasterRepairIndicesCount,
            1,
            "Missing raster for item 5 should be detected"
        )

        // Bitmap should still be blank immediately after detection
        let bitmapsAtItem5Blank = feed._debugPaintedBitmaps(at: 5)
        XCTAssertNil(
            bitmapsAtItem5Blank[0],
            "Bitmap should still be blank after detection (repair is async)"
        )

        // Poll for repair to complete
        await waitForRepairCompletion(feed)
        await waitForBitmapPaint(feed, at: 5, fragmentId: 0)

        // Verify repair completed and pending count is cleared
        XCTAssertEqual(
            feed._pendingRasterRepairIndicesCount,
            0,
            "All repair indices should be cleared after repair completes"
        )

        // Verify bitmap is now painted
        let bitmapsAtItem5After = feed._debugPaintedBitmaps(at: 5)
        XCTAssertNotNil(
            bitmapsAtItem5After[0],
            "Bitmap should be painted after repair completes for item 5"
        )
    }
}
#endif
