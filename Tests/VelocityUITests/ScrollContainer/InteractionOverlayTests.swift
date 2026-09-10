// InteractionOverlayTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class InteractionOverlayTests: XCTestCase {

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
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore()
        )
    }

    private func makeFeed(width: CGFloat = 375, height: CGFloat = 812) -> FeedScrollView<TestItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: height))
        feed.cellBuilder = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }
        return feed
    }

    private func items(count: Int, aspectRatio: CGFloat = 1.5) -> [TestItem] {
        (0..<count).map { TestItem(id: $0, aspectRatio: aspectRatio) }
    }

    // MARK: - Test 1: Tap on a visible cell reports correct item + window-coordinate frame

    func testTapOnVisibleCellReportsCorrectItemAndWindowFrame() {
        let feed = makeFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        // Pick an index known to be visible (e.g., index 1).
        let visibleIndices = Array(feed.visibleCells.keys).sorted()
        guard visibleIndices.count >= 2 else {
            XCTFail("Expected at least 2 visible items")
            return
        }

        let testIndex = visibleIndices[1]
        guard let contentFrame = feed.frameMap[testIndex] else {
            XCTFail("frameMap[\(testIndex)] must be non-nil for a visible cell")
            return
        }

        let tapPoint = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
        var capturedItem: TestItem?
        var capturedFrame: CGRect?

        feed.onTap = { item, frame in
            capturedItem = item
            capturedFrame = frame
        }

        feed.handleTap(at: tapPoint)

        XCTAssertNotNil(capturedItem, "onTap callback must be called with an item")
        XCTAssertEqual(capturedItem?.id, testIndex, "Tapped item ID must match the frameMap index")

        let expectedWindowFrame = feed.convert(contentFrame, to: nil)
        XCTAssertNotNil(capturedFrame, "onTap callback must be called with a frame")
        XCTAssertEqual(capturedFrame?.origin.x ?? 0, expectedWindowFrame.origin.x, accuracy: 0.01, "Frame X must match window coordinates")
        XCTAssertEqual(capturedFrame?.origin.y ?? 0, expectedWindowFrame.origin.y, accuracy: 0.01, "Frame Y must match window coordinates")
        XCTAssertEqual(capturedFrame?.width ?? 0, expectedWindowFrame.width, accuracy: 0.01, "Frame width must match")
        XCTAssertEqual(capturedFrame?.height ?? 0, expectedWindowFrame.height, accuracy: 0.01, "Frame height must match")
    }

    // MARK: - Test 2: Tap on a gap (no frame contains the point) is a no-op

    func testTapOnGapIsNoOp() {
        let feed = makeFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        var tapFired = false
        feed.onTap = { _, _ in
            tapFired = true
        }

        // Tap far outside content bounds.
        let gapPoint = CGPoint(x: -500, y: -500)
        feed.handleTap(at: gapPoint)

        XCTAssertFalse(tapFired, "onTap must not fire when tapping outside all frame bounds")
    }

    // MARK: - Test 3: resolveTappedIndex returns nil for a point between two frames

    func testResolveTappedIndexReturnsNilInGap() throws {
        let feed = makeFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        let visibleIndices = Array(feed.visibleCells.keys).sorted()
        guard visibleIndices.count >= 2 else {
            throw XCTSkip("Need at least 2 visible items")
        }

        let idx1 = visibleIndices[0]
        let idx2 = visibleIndices[1]

        guard let frame1 = feed.frameMap[idx1],
              let frame2 = feed.frameMap[idx2],
              frame2.minY > frame1.maxY else {
            throw XCTSkip("No vertical gap between these adjacent frames")
        }

        // Pick a point in the gap.
        let gapY = frame1.maxY + (frame2.minY - frame1.maxY) / 2
        let pointInGap = CGPoint(x: frame1.midX, y: gapY)

        let resolvedIndex = feed.resolveTappedIndex(at: pointInGap)
        XCTAssertNil(resolvedIndex, "resolveTappedIndex must return nil for a point strictly between two frames")
    }

    // MARK: - Test 4: VoiceOver enumerates every visible cell with a label

    func testVoiceOverEnumeratesEveryVisibleCell() {
        let feed = makeFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        let accessibilityElements = feed.interactionOverlay.accessibilityElements ?? []
        XCTAssertEqual(accessibilityElements.count, feed.visibleCells.count,
            "Accessibility element count must equal visible cell count")

        // Verify a specific visible index has the expected label.
        let visibleIndices = Array(feed.visibleCells.keys).sorted()
        guard let firstVisibleIndex = visibleIndices.first else {
            XCTFail("Expected at least one visible item")
            return
        }

        guard let element = feed.accessibilityElementsByIndex[firstVisibleIndex] else {
            XCTFail("accessibilityElementsByIndex[\(firstVisibleIndex)] must be non-nil")
            return
        }

        let expectedLabel = String(describing: feed.items[firstVisibleIndex])
        XCTAssertEqual(element.accessibilityLabel, expectedLabel,
            "Default accessibility label must be String(describing: item)")
    }

    // MARK: - Test 5: Custom cellAccessibilityLabel closure is used when set

    func testCustomCellAccessibilityLabelIsUsed() {
        let feed = makeFeed()
        feed.cellAccessibilityLabel = { item in "Item #\(item.id)" }
        feed.items = items(count: 20)
        feed.layoutSubviews()

        let visibleIndices = Array(feed.visibleCells.keys).sorted()
        guard let firstVisibleIndex = visibleIndices.first else {
            XCTFail("Expected at least one visible item")
            return
        }

        guard let element = feed.accessibilityElementsByIndex[firstVisibleIndex] else {
            XCTFail("accessibilityElementsByIndex[\(firstVisibleIndex)] must be non-nil")
            return
        }

        XCTAssertEqual(element.accessibilityLabel, "Item #\(firstVisibleIndex)",
            "Custom cellAccessibilityLabel must be applied to the accessibility element")
    }

    // MARK: - Test 6: frameMap stays consistent with visibleCells after programmatic scroll

    func testFrameMapConsistencyAfterScroll() {
        let feed = makeFeed()
        feed.items = items(count: 50)
        feed.layoutSubviews()

        // Scroll down significantly.
        feed.contentOffset = CGPoint(x: 0, y: 2000)
        feed.layoutSubviews()

        // After scroll, frameMap keys must match visibleCells keys exactly.
        let frameMapKeys = Set(feed.frameMap.keys)
        let visibleCellKeys = Set(feed.visibleCells.keys)

        XCTAssertEqual(frameMapKeys, visibleCellKeys,
            "frameMap keys must exactly match visibleCells keys after scroll")

        // Verify each visible index has a corresponding frame.
        for index in visibleCellKeys {
            XCTAssertNotNil(feed.frameMap[index],
                "frameMap[\(index)] must be non-nil for all visible indices")
        }

        // Verify frameMap count equals visibleCells count (no stale entries).
        XCTAssertEqual(feed.frameMap.keys.count, feed.visibleCells.keys.count,
            "frameMap count must equal visibleCells count, with no stale leftover indices")
    }

    // MARK: - Test 7: Recycled-out indices are dropped from frameMap and accessibilityElementsByIndex

    func testRecycledOutIndicesAreDropped() {
        let feed = makeFeed()
        feed.items = items(count: 50)
        feed.layoutSubviews()

        // Record an index that is visible initially (e.g., index 0).
        guard feed.visibleCells[0] != nil else {
            XCTFail("Index 0 must be visible after initial layout")
            return
        }

        XCTAssertNotNil(feed.frameMap[0], "frameMap[0] must be non-nil initially")

        // Scroll past it, far enough to recycle it out.
        feed.contentOffset = CGPoint(x: 0, y: 5000)
        feed.layoutSubviews()

        // Index 0 should no longer be visible.
        XCTAssertNil(feed.visibleCells[0],
            "Index 0 must be recycled out after large scroll")

        // frameMap and accessibilityElementsByIndex must also drop it (not leak).
        XCTAssertNil(feed.frameMap[0],
            "frameMap[0] must be nil after index 0 is recycled out")
        XCTAssertNil(feed.accessibilityElementsByIndex[0],
            "accessibilityElementsByIndex[0] must be nil after index 0 is recycled out")
    }

    // MARK: - Test 8: accessibilityFrameInContainerSpace reflects overlay-local coordinates

    func testAccessibilityFrameInContainerSpaceIsOverlayLocal() {
        let feed = makeFeed()
        feed.items = items(count: 50)
        feed.layoutSubviews()

        // Scroll to a non-zero offset so content frame and window frame differ.
        feed.contentOffset = CGPoint(x: 0, y: 500)
        feed.layoutSubviews()

        let visibleIndices = Array(feed.visibleCells.keys).sorted()
        guard let testIndex = visibleIndices.first else {
            XCTFail("Expected at least one visible item after scroll")
            return
        }

        guard let contentFrame = feed.frameMap[testIndex] else {
            XCTFail("frameMap[\(testIndex)] must be non-nil")
            return
        }

        guard let element = feed.accessibilityElementsByIndex[testIndex] else {
            XCTFail("accessibilityElementsByIndex[\(testIndex)] must be non-nil")
            return
        }

        // Compute expected local rect (overlay-relative).
        let overlayOrigin = feed.interactionOverlay.frame.origin
        let expectedX = contentFrame.minX - overlayOrigin.x
        let expectedY = contentFrame.minY - overlayOrigin.y
        let expectedWidth = contentFrame.width
        let expectedHeight = contentFrame.height

        let actualFrame = element.accessibilityFrameInContainerSpace

        XCTAssertEqual(actualFrame.origin.x, expectedX, accuracy: 0.01,
            "Accessibility frame X must be overlay-local (contentFrame.minX - overlay.origin.x)")
        XCTAssertEqual(actualFrame.origin.y, expectedY, accuracy: 0.01,
            "Accessibility frame Y must be overlay-local (contentFrame.minY - overlay.origin.y)")
        XCTAssertEqual(actualFrame.width, expectedWidth, accuracy: 0.01,
            "Accessibility frame width must match contentFrame width")
        XCTAssertEqual(actualFrame.height, expectedHeight, accuracy: 0.01,
            "Accessibility frame height must match contentFrame height")
    }
}

#endif
