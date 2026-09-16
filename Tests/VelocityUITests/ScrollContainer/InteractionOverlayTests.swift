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
            hotCodeStreamStore: HotCodeStreamStore(), hotTableRasterizerStore: HotTableRasterizerStore()
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

    /* Disabled while the tap/action API is unavailable.
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
    */

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

    // MARK: - Per-node action-id hit-test (VelocityUI-ye8a.2)

    /* Disabled while the tap/action API is unavailable.

    private enum ActionTag: Hashable, Sendable {
        case card(Int)
        case icon(Int)
        case tagged(Int)
    }

    /// One tagged leaf ("Icon", tagged `.icon`) nested inside a tagged container ("Card
    /// \(item.id)", tagged `.card`) -- both wrap the same point, so a tap there must resolve to
    /// the deeper `.icon` tag, not the shallower `.card` one.
    private func makeNestedTaggedFeed(width: CGFloat = 375, height: CGFloat = 812) -> FeedScrollView<TestItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: height))
        feed.cellBuilder = { item in
            VStackNode(alignment: .leading, spacing: 4) {
                TextNode("Card \(item.id)")
                TextNode("Icon").action(ActionTag.icon(item.id))
            }
            .action(ActionTag.card(item.id))
        }
        return feed
    }

    /// One tagged leaf ("Tagged") and one untagged sibling ("Untagged") -- the VStack itself
    /// carries no tag, so a tap on "Untagged" must miss the hit-test entirely and fall through
    /// to the existing item-level `onTap`.
    private func makePartiallyTaggedFeed(width: CGFloat = 375, height: CGFloat = 812) -> FeedScrollView<TestItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: height))
        feed.cellBuilder = { item in
            VStackNode(alignment: .leading, spacing: 4) {
                TextNode("Tagged").action(ActionTag.tagged(item.id))
                TextNode("Untagged")
            }
        }
        return feed
    }

    /// Text content is a `WorkingRange` miss on the first synchronous `layoutSubviews()` (real
    /// fragments arrive off the async pipeline) -- polls with real fragments, mirroring the
    /// `waitForWorkingRangeCommit` helper other ScrollContainer test files use for the same reason.
    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<TestItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    /// Cell-local frame of the fragment carrying `actionID`, or `nil` if no committed fragment
    /// for `index` carries it. Tests read this straight from `WorkingRange` (the same source
    /// `syncActionFrames` reads) rather than hand-computing text measurement.
    private func taggedFragmentFrame(
        _ feed: FeedScrollView<TestItem>, index: Int, actionID: ActionID
    ) -> CGRect? {
        feed.workingRange.entry(at: index)?.fragments.first { $0.actionID == actionID }?.frame
    }

    private func contentPoint(
        _ feed: FeedScrollView<TestItem>, index: Int, actionID: ActionID
    ) -> CGPoint? {
        guard let cellFrame = feed.frameMap[index],
              let fragmentFrame = taggedFragmentFrame(feed, index: index, actionID: actionID)
        else { return nil }
        return CGPoint(x: cellFrame.minX + fragmentFrame.midX, y: cellFrame.minY + fragmentFrame.midY)
    }

    func testTapOnTaggedNodeReportsCorrectItemAndActionID() async throws {
        let feed = makeNestedTaggedFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        guard let testIndex = feed.visibleCells.keys.sorted().first else {
            throw XCTSkip("Expected at least one visible item")
        }
        await waitForWorkingRangeCommit(feed, index: testIndex)
        let expectedActionID = ActionID(ActionTag.icon(testIndex))
        guard let tapPoint = contentPoint(feed, index: testIndex, actionID: expectedActionID) else {
            throw XCTSkip("Icon fragment not committed for index \(testIndex)")
        }

        var capturedItem: TestItem?
        var capturedActionID: ActionID?
        var onTapFired = false
        feed.onTap = { _, _ in onTapFired = true }
        feed.onNodeTap = { item, actionID, _ in
            capturedItem = item
            capturedActionID = actionID
        }

        feed.handleTap(at: tapPoint)

        XCTAssertEqual(capturedItem?.id, testIndex, "onNodeTap must report the tapped item")
        XCTAssertEqual(capturedActionID, expectedActionID, "onNodeTap must report the deepest tagged node's actionID")
        XCTAssertFalse(onTapFired, "A tap resolved to a tagged node must not also fire item-level onTap")
        await drainFeedWork(feed)
    }

    func testTapOnNestedTaggedNodeResolvesToDeepestTag() async throws {
        let feed = makeNestedTaggedFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        guard let testIndex = feed.visibleCells.keys.sorted().first else {
            throw XCTSkip("Expected at least one visible item")
        }
        await waitForWorkingRangeCommit(feed, index: testIndex)
        let iconActionID = ActionID(ActionTag.icon(testIndex))
        let cardActionID = ActionID(ActionTag.card(testIndex))
        guard let tapPoint = contentPoint(feed, index: testIndex, actionID: iconActionID) else {
            throw XCTSkip("Icon fragment not committed for index \(testIndex)")
        }
        // Sanity: the tap point must genuinely sit inside BOTH the card's and the icon's rect,
        // or this isn't testing the nested-overlap case at all.
        guard let cardFrame = taggedFragmentFrame(feed, index: testIndex, actionID: cardActionID),
              let cellFrame = feed.frameMap[testIndex],
              cardFrame.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY).contains(tapPoint)
        else {
            throw XCTSkip("Card fragment doesn't enclose the icon tap point")
        }

        var capturedActionID: ActionID?
        feed.onNodeTap = { _, actionID, _ in capturedActionID = actionID }

        feed.handleTap(at: tapPoint)

        XCTAssertEqual(capturedActionID, iconActionID, "The deeper tag (icon) must win over the shallower enclosing tag (card)")
        await drainFeedWork(feed)
    }

    func testTapOnUntaggedRegionStillFiresItemLevelOnTap() async throws {
        let feed = makePartiallyTaggedFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        guard let testIndex = feed.visibleCells.keys.sorted().first else {
            throw XCTSkip("Expected at least one visible item")
        }
        await waitForWorkingRangeCommit(feed, index: testIndex)
        guard let entry = feed.workingRange.entry(at: testIndex),
              let untaggedFragment = entry.fragments.first(where: { $0.actionID == nil && $0.content.isTextContent }),
              let cellFrame = feed.frameMap[testIndex]
        else {
            throw XCTSkip("Untagged text fragment not committed for index \(testIndex)")
        }
        let tapPoint = CGPoint(
            x: cellFrame.minX + untaggedFragment.frame.midX,
            y: cellFrame.minY + untaggedFragment.frame.midY
        )

        var capturedItem: TestItem?
        var nodeTapFired = false
        feed.onTap = { item, _ in capturedItem = item }
        feed.onNodeTap = { _, _, _ in nodeTapFired = true }

        feed.handleTap(at: tapPoint)

        XCTAssertEqual(capturedItem?.id, testIndex, "Tapping an untagged region must still fire item-level onTap (b6u regression guard)")
        XCTAssertFalse(nodeTapFired, "Tapping an untagged region must not fire onNodeTap")
        await drainFeedWork(feed)
    }

    func testTapOnGapFiresNeitherOnTapNorOnNodeTap() {
        let feed = makeNestedTaggedFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        var onTapFired = false
        var nodeTapFired = false
        feed.onTap = { _, _ in onTapFired = true }
        feed.onNodeTap = { _, _, _ in nodeTapFired = true }

        feed.handleTap(at: CGPoint(x: -500, y: -500))

        XCTAssertFalse(onTapFired, "onTap must not fire when tapping outside all frame bounds")
        XCTAssertFalse(nodeTapFired, "onNodeTap must not fire when tapping outside all frame bounds")
    }

    func testActionFrameMapConsistentWithVisibleCellsAcrossNoOpLayoutPass() {
        let feed = makeNestedTaggedFeed()
        feed.items = items(count: 20)
        feed.layoutSubviews()

        let keysBefore = Set(feed.actionFrameMap.keys)
        XCTAssertEqual(keysBefore, Set(feed.visibleCells.keys),
            "actionFrameMap keys must exactly match visibleCells keys after initial mount")

        // A second layout pass with no scroll/items change must not touch mount/unmount sites --
        // syncActionFrames only runs there, so the map must come out byte-for-byte identical.
        feed.layoutSubviews()

        XCTAssertEqual(Set(feed.actionFrameMap.keys), keysBefore,
            "actionFrameMap must stay unchanged across a no-op layout pass (mount-only, never per-frame)")
    }
    */
}

private extension FragmentContent {
    var isTextContent: Bool {
        if case .text = self { return true }
        return false
    }
}

#endif
