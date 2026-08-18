// StreamingMarkdownFeedIntegrationTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers VelocityUI-zuot end-to-end: an app-owned `IncrementalMarkdownParser`, stored on the
/// `Item` and mutated with `.append(_:)` as tokens arrive, rendered via
/// `IncrementalMarkdownParser.renderNodes` inside a `VStackNode` — driven through the SAME
/// production `FeedScrollView` C3 bind site `FeedScrollViewBlockDiffTests` already covers for
/// hand-authored blocks. This file exists to prove the DSL bridge added by this bead needs zero
/// changes to `flatBlocks`/`applyInPlaceBlockDiff`/`diff` — real parser output flows through
/// unmodified.
@MainActor
final class StreamingMarkdownFeedIntegrationTests: XCTestCase {

    // MARK: - Fixture

    /// A streaming chat message: the app owns `markdownParser` and calls `.append(_:)` itself as
    /// tokens arrive, then pushes a fresh value into `FeedScrollView.items` — exactly the pattern
    /// this bead's design (`bd show VelocityUI-zuot`) settled on ("Option A").
    struct StreamingMessage: Identifiable, Sendable {
        let id: Int
        var markdownParser: IncrementalMarkdownParser
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
            hotBlockRasterizerStore: HotBlockRasterizerStore()
        )
    }

    private func makeStreamingFeed(environment: RenderEnvironment? = nil) -> FeedScrollView<StreamingMessage> {
        let env = environment ?? makeEnvironment()
        let feed = FeedScrollView<StreamingMessage>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(alignment: .leading, spacing: 4) {
                item.markdownParser.renderNodes
            }
        }
        return feed
    }

    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<StreamingMessage>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    // MARK: - Token-by-token streaming keeps the same cell and grows height

    func testTokenByTokenAppend_KeepsSameCell_HeightGrowsMonotonically() async {
        let feed = makeStreamingFeed()
        var parser = IncrementalMarkdownParser()
        parser.append("Hello")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let cellBefore = feed._cellLayer(at: 0)
        let returnToPoolBefore = feed._returnToPoolCount
        var heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightBefore, 0, "Precondition: item 0 must have a real measured height")

        let tokens = [" world", " this", " is", " a", " streaming", " markdown", " message", " that", " keeps", " growing"]
        for token in tokens {
            parser.append(token)
            feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
            feed.layoutSubviews()

            XCTAssertTrue(cellBefore === feed._cellLayer(at: 0),
                "same-id streaming update must keep the same cell (.inPlace), never recycle")
            XCTAssertEqual(feed._returnToPoolCount, returnToPoolBefore,
                "same-id streaming update must never return the shell to the pool")

            let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
            XCTAssertGreaterThanOrEqual(heightAfter, heightBefore,
                "height must never shrink while pure text keeps appending to the same paragraph")
            heightBefore = heightAfter
        }

        await drainFeedWork(feed)
    }

    // MARK: - A block that seals (blank line arrives) freezes into FrozenBitmapStore

    func testParagraphSeals_OnBlankLine_FreezesIntoBitmapStore() async {
        let feed = makeStreamingFeed()
        var parser = IncrementalMarkdownParser()
        parser.append("First paragraph, still growing")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Seal the first paragraph (blank line) and start a second one — mirrors
        // FeedScrollViewBlockDiffTests' "a second block appears -> block0 must finalize/freeze".
        parser.append(".\n\nSecond paragraph starts")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        XCTAssertEqual(parser.frontier, 1, "Precondition: the blank line must have sealed exactly the first block")

        let key0 = BlockKey(itemID: 0, index: 0)
        guard let expectedBitmap = feed.renderEnvironment.frozenBitmapStore.bitmap(for: key0) else {
            return XCTFail("the sealed first block must be frozen into FrozenBitmapStore")
        }

        let painted = feed._debugPaintedBitmaps(at: 0)
        XCTAssertEqual(painted.count, 2, "both the frozen first block and the still-hot second block must paint real bitmaps")
        XCTAssertTrue(painted.values.contains(where: { $0 === expectedBitmap }),
            "the frozen block's exact FrozenBitmapStore bitmap instance must be what's painted on screen")

        // Growing only the second (still-hot) paragraph must route through the hot-append path
        // and must NEVER touch block0's frozen entry again.
        let hotAppendCountBefore = feed._blockDiffHotAppendCallCount
        parser.append(" and keeps streaming further")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()

        XCTAssertGreaterThan(feed._blockDiffHotAppendCallCount, hotAppendCountBefore,
            "growing only the trailing block must engage the O(appended) hot-append path")
        let paintedAfter = feed._debugPaintedBitmaps(at: 0)
        XCTAssertTrue(paintedAfter.values.contains(where: { $0 === expectedBitmap }),
            "the sealed block's bitmap instance must be untouched by the second block's growth")

        await drainFeedWork(feed)
    }
}
#endif
