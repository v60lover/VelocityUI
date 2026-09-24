// TextNodeResolverTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class TextNodeResolverTests: XCTestCase {
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
            hotCodeStreamStore: HotCodeStreamStore(), hotTableRasterizerStore: HotTableRasterizerStore()
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

    private func waitForCommit(_ feed: FeedScrollView<TestItem>, index: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    func testLongPressOnTextReturnsItsDescriptorAndRect() async throws {
        let feed = makeFeed()
        feed.items = (0..<5).map { TestItem(id: $0) }
        feed.layoutSubviews()
        let index = try XCTUnwrap(feed.visibleCells.keys.sorted().first)
        await waitForCommit(feed, index: index)
        let table = feed.tables[index]
        let entry = try XCTUnwrap(feed.workingRange.entry(at: index))
        let cell = try XCTUnwrap(feed.frameMap[index])
        let frag = try XCTUnwrap(entry.fragments.first { if case .text = table.nodes[$0.id] { return true } else { return false } })
        let point = CGPoint(x: cell.minX + frag.frame.midX, y: cell.minY + frag.frame.midY)

        let hit = try XCTUnwrap(feed.resolveTextNode(at: point, in: index))
        XCTAssertEqual(hit.descriptor.content, "Paragraph \(index)")
        guard case .text = table.nodes[hit.nodeIndex] else { return XCTFail("hit must be a .text node") }
        XCTAssertTrue(hit.rect.contains(point))
    }

    func testLongPressOnImageReturnsNil() async throws {
        let feed = makeFeed()
        feed.items = (0..<5).map { TestItem(id: $0) }
        feed.layoutSubviews()
        let index = try XCTUnwrap(feed.visibleCells.keys.sorted().first)
        await waitForCommit(feed, index: index)
        let table = feed.tables[index]
        let entry = try XCTUnwrap(feed.workingRange.entry(at: index))
        let cell = try XCTUnwrap(feed.frameMap[index])
        let image = try XCTUnwrap(entry.fragments.first { if case .image = table.nodes[$0.id] { return true } else { return false } })
        let point = CGPoint(x: cell.minX + image.frame.midX, y: cell.minY + image.frame.midY)

        XCTAssertNil(feed.resolveTextNode(at: point, in: index), "non-text node must not start selection")
    }
}
#endif
