// TextSelectionWiringTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class TextSelectionWiringTests: XCTestCase {
    struct TestItem: Identifiable, Sendable { let id: Int }

    private func makeFeed() -> FeedScrollView<TestItem> {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
            textPool: TextMeasurementPool(), layoutCache: LayoutCache(), dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc), gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep, frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore(), hotTableRasterizerStore: HotTableRasterizerStore(), streamingDeliveryCoordinator: StreamingDeliveryCoordinator()
        )
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(alignment: .leading, spacing: 4) {
                TextNode("Paragraph \(item.id)")
                AsyncImageNode(url: nil, aspectRatio: 1.5)
            }
        }
        return feed
    }

    /// Feed with committed layouts, plus the content-space points of the first item's text and image.
    private func committedFeed() async throws -> (feed: FeedScrollView<TestItem>, text: CGPoint, image: CGPoint) {
        let feed = makeFeed()
        feed.items = (0..<5).map { TestItem(id: $0) }
        feed.layoutSubviews()
        let index = try XCTUnwrap(feed.visibleCells.keys.sorted().first)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, feed._workingRangeMissCount(from: index, to: index + 1) != 0 {
            await Task.yield()
            feed.layoutSubviews()
        }
        let table = feed.tables[index]
        let entry = try XCTUnwrap(feed.workingRange.entry(at: index))
        let cell = try XCTUnwrap(feed.frameMap[index])
        let textFrag = try XCTUnwrap(entry.fragments.first { if case .text = table.nodes[$0.id] { return true } else { return false } })
        let imageFrag = try XCTUnwrap(entry.fragments.first { if case .image = table.nodes[$0.id] { return true } else { return false } })
        return (
            feed,
            CGPoint(x: cell.minX + textFrag.frame.minX + 2, y: cell.minY + textFrag.frame.midY),
            CGPoint(x: cell.minX + imageFrag.frame.midX, y: cell.minY + imageFrag.frame.midY)
        )
    }

    func testLongPressOnTextStartsSelectionWithHighlight() async throws {
        let (feed, text, _) = try await committedFeed()
        feed.beginLongPress(at: text)
        XCTAssertTrue(feed.textSelection.isActive)
        XCTAssertEqual(feed.textSelection.session?.copiedText, "Paragraph")
        XCTAssertGreaterThanOrEqual(feed.textSelection.highlightLayer.sublayers?.count ?? 0, 1)
    }

    func testLongPressOnImageGoesToNodeLongPress() async throws {
        let (feed, _, image) = try await committedFeed()
        var fired = 0
        feed.onNodeLongPress = { _, _, _ in fired += 1 }
        feed.beginLongPress(at: image)
        XCTAssertFalse(feed.textSelection.isActive)
        XCTAssertEqual(fired, 1)
    }

    func testTapOutsideDeselectsAndInsideKeepsSelection() async throws {
        let (feed, text, image) = try await committedFeed()
        feed.beginLongPress(at: text)
        feed.handleTap(at: text)
        XCTAssertTrue(feed.textSelection.isActive, "tap inside the selection keeps it")
        feed.handleTap(at: image)
        XCTAssertFalse(feed.textSelection.isActive)
        XCTAssertEqual(feed.textSelection.highlightLayer.sublayers?.count ?? 0, 0)
    }

    func testPansRefuseToBeginOnlyWhileSelectionIsActive() async throws {
        let (feed, text, _) = try await committedFeed()
        XCTAssertTrue(feed.gestureRecognizerShouldBegin(feed.panGestureRecognizer))
        feed.beginLongPress(at: text)
        XCTAssertFalse(feed.gestureRecognizerShouldBegin(feed.panGestureRecognizer))
        let codeDelegate = HorizontalCodePanDirectionDelegate()
        codeDelegate.isBlocked = { feed.textSelection.isActive }
        XCTAssertFalse(codeDelegate.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
        feed.textSelection.clear()
        XCTAssertTrue(feed.gestureRecognizerShouldBegin(feed.panGestureRecognizer))
    }

    func testSelectionDropsSilentlyWhenItsItemIsRemoved() async throws {
        let (feed, text, _) = try await committedFeed()
        feed.beginLongPress(at: text)
        feed.items = []
        feed.layoutSubviews()
        XCTAssertFalse(feed.textSelection.isActive)
    }

    func testCopyPutsRawTextOnPasteboard() async throws {
        let (feed, text, _) = try await committedFeed()
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let controller = TextSelectionController(pasteboard: board)
        let session = try XCTUnwrap(feed.textSelection.session ?? {
            feed.beginLongPress(at: text)
            return feed.textSelection.session
        }())
        XCTAssertTrue(controller.begin(
            session, itemID: 0, layoutHash: 0, cellOrigin: .zero, width: 0, at: text
        ))
        controller.copySelection()
        XCTAssertEqual(board.string, "Paragraph")
    }
}
#endif
