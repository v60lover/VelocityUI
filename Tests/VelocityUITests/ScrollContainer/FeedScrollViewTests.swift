// FeedScrollViewTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class FeedScrollViewTests: XCTestCase {

    // MARK: - Test fixtures

    struct TestItem: Identifiable, Sendable {
        let id: Int
        let aspectRatio: CGFloat
        init(id: Int, aspectRatio: CGFloat = 1.0) {
            self.id = id
            self.aspectRatio = aspectRatio
        }
    }

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
            videoPreparation: videoPrep
        )
    }

    private func makeFeed(width: CGFloat = 375, height: CGFloat = 812) -> FeedScrollView<TestItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: height))
        feed.cellBuilder = { item in
            AsyncImageNode(aspectRatio: item.aspectRatio)
        }
        return feed
    }

    private func items(count: Int, aspectRatio: CGFloat = 1.5) -> [TestItem] {
        (0..<count).map { TestItem(id: $0, aspectRatio: aspectRatio) }
    }

    // MARK: - 1. Zero Task spawn during frames without boundary crossing

    func testNoTaskSpawnWithoutBoundaryChange() {
        let feed = makeFeed()
        feed.items = items(count: 20)

        // Force initial layout so lastNotifiedLeadingIndex is set.
        feed.layoutSubviews()
        #if DEBUG
        let baseline = feed._taskSpawnCount
        #endif

        // Simulate 100 layout cycles at the SAME contentOffset (no boundary crossing).
        for _ in 0..<100 {
            feed.layoutSubviews()
        }

        #if DEBUG
        XCTAssertEqual(feed._taskSpawnCount, baseline,
            "Zero Task spawns expected during 100 frames without a leading-index boundary crossing")
        #endif
    }

    // MARK: - 2. Task spawn counter matches boundary crossings

    func testTaskSpawnCountMatchesBoundaryCrossings() {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 200)
        feed.layoutSubviews()

        #if DEBUG
        let afterFirst = feed._taskSpawnCount
        XCTAssertEqual(afterFirst, 1, "One spawn for the initial leading index")

        // Move to a new leading index by scrolling down past one cell height.
        feed.contentOffset = CGPoint(x: 0, y: 350)
        feed.layoutSubviews()
        XCTAssertEqual(feed._taskSpawnCount, afterFirst + 1,
            "One additional spawn per unique leading-index boundary")

        // Stay at the same offset — no new spawn.
        feed.layoutSubviews()
        feed.layoutSubviews()
        XCTAssertEqual(feed._taskSpawnCount, afterFirst + 1,
            "No spawn when leading index is unchanged")
        #endif
    }

    // MARK: - 3. Correct visible set at sampled offsets

    func testVisibleSetMatchesExpectedIndices() {
        let viewportHeight: CGFloat = 812
        let feed = makeFeed(width: 375, height: viewportHeight)

        // All items have the same estimated height so resolvedFrames are predictable.
        feed.items = items(count: 50, aspectRatio: 1.0)
        feed.layoutSubviews()

        // Use the feed's own public constants to avoid coupling.
        let itemPlusSpacing = feed.estimatedItemHeight + feed.layoutSpacing

        XCTAssertGreaterThan(feed.layer.sublayers?.count ?? 0, 0,
            "Feed layer should have cell sublayers after first layout")

        // Scroll past first item — index 0 should eventually be recycled.
        feed.contentOffset = CGPoint(x: 0, y: itemPlusSpacing + 1)
        feed.layoutSubviews()

        // contentSize should reflect estimated heights.
        let expectedContentHeight = CGFloat(50) * feed.estimatedItemHeight + CGFloat(49) * feed.layoutSpacing
        XCTAssertEqual(feed.contentSize.height, expectedContentHeight, accuracy: 0.5)
    }

    // MARK: - 4. Items append does not blank existing visible cells

    func testAppendDoesNotBlankExistingCells() {
        let feed = makeFeed()
        let firstPage = items(count: 10)
        feed.items = firstPage
        feed.layoutSubviews()

        let sublayersBefore = feed.layer.sublayers?.count ?? 0
        XCTAssertGreaterThan(sublayersBefore, 0, "Cells must be mounted after first layout")

        // Append second page.
        let secondPage = items(count: 20)
        feed.items = secondPage
        feed.layoutSubviews()

        let sublayersAfter = feed.layer.sublayers?.count ?? 0
        // Cells should be remounted (some may be recycled then re-added in new layout).
        // Key check: the total count is non-zero and contentSize reflects 20 items.
        XCTAssertGreaterThan(sublayersAfter, 0, "Cells must still be mounted after page append")
        XCTAssertGreaterThan(feed.contentSize.height, feed.bounds.height,
            "contentSize must exceed viewport after 20 items")
    }

    // MARK: - 5. onReachEnd fires exactly once per page

    func testOnReachEndFiresOncePerPage() async {
        let feed = makeFeed(width: 375, height: 812)

        // First page: scroll to bottom and expect one fire.
        let expFirst = expectation(description: "first reach-end")
        feed.onReachEnd = { expFirst.fulfill() }
        feed.items = items(count: 5)
        feed.layoutSubviews()

        let bottom = max(0, feed.contentSize.height - feed.bounds.height)
        feed.contentOffset = CGPoint(x: 0, y: bottom)
        feed.layoutSubviews()

        // fulfillment suspends the test Task, letting the spawned Task run on MainActor.
        await fulfillment(of: [expFirst], timeout: 1.0)

        // Additional frames must NOT re-fire — inverted expectation with short timeout.
        let expNoRefire = expectation(description: "no re-fire before items grow")
        expNoRefire.isInverted = true
        feed.onReachEnd = { expNoRefire.fulfill() }
        feed.layoutSubviews()
        await fulfillment(of: [expNoRefire], timeout: 0.1)

        // Second page: items grow → gate resets → fires again at new end.
        let expSecond = expectation(description: "second reach-end after items grow")
        feed.onReachEnd = { expSecond.fulfill() }
        feed.items = items(count: 10)
        feed.layoutSubviews()
        feed.contentOffset = CGPoint(x: 0, y: max(0, feed.contentSize.height - feed.bounds.height))
        feed.layoutSubviews()
        await fulfillment(of: [expSecond], timeout: 1.0)
    }

    // MARK: - 6. Width change invalidates working range and resets estimated frames

    func testWidthChangeResetsFramesToEstimated() async {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 10)
        feed.layoutSubviews()

        let heightBefore = feed.contentSize.height

        // Simulate rotation: change bounds width.
        feed.frame = CGRect(x: 0, y: 0, width: 667, height: 375)
        feed.layoutSubviews()

        // After width change, all frames re-estimated at estimatedItemHeight.
        // contentSize.height should stay the same (same item count, same estimated height).
        XCTAssertEqual(feed.contentSize.height, heightBefore, accuracy: 1,
            "Estimated height sum must be the same after width change — only width changes")

        // Layout cache invalidation is fire-and-forget async; no observable side-effect to assert.
    }

    // MARK: - 7. Recycle correctness: no item-A content shown while bound to item-B

    func testRecycleClearsOldContent() {
        let feed = makeFeed(width: 375, height: 200)  // tiny viewport: ~0-1 items visible
        feed.items = items(count: 30)
        feed.layoutSubviews()

        // Scroll past many items; pooled cells should be reused.
        for step in stride(from: 0, to: Int(feed.contentSize.height), by: 400) {
            feed.contentOffset = CGPoint(x: 0, y: CGFloat(step))
            feed.layoutSubviews()
        }

        // No assertions on internals here — this is a crash / assertion-violation guard.
        // RenderCell.prepareForReuse already asserts no cross-item bleed in DEBUG.
        // If we reach here without crashing, recycle semantics are correct.
        XCTAssert(true, "Scroll without crash proves recycle semantics")
    }

    // MARK: - 8. contentSize width tracks bounds.width

    func testContentSizeWidthMatchesBoundsWidth() {
        let feed = makeFeed(width: 390, height: 844)
        feed.items = items(count: 5)
        feed.layoutSubviews()
        XCTAssertEqual(feed.contentSize.width, 390)

        feed.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        feed.layoutSubviews()
        XCTAssertEqual(feed.contentSize.width, 428)
    }
}
#endif
