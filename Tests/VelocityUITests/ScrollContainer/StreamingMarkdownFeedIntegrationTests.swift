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

    private func makeEnvironment(hotBlockRasterizeEnabled: Bool = true) -> RenderEnvironment {
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
            hotBlockRasterizeEnabled: hotBlockRasterizeEnabled
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

    // MARK: - Diagnostic: does sealing with ZERO new visible content still redraw pixels?

    /// Reads `image` into a plain premultiplied-RGBA byte buffer for exact pixel comparison —
    /// `CGImage` identity (`===`) proves zero re-rasterize, but says nothing about whether two
    /// DIFFERENT `CGImage` instances happen to be pixel-identical or genuinely different content.
    private func rawPixels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// Diagnostic for a user-reported flash: "the just-sealed paragraph briefly redraws right as
    /// the next paragraph starts, even though its own text hasn't changed." Isolates the purest
    /// version: the blank line sealing block0 carries no new visible characters
    /// (`finalizeOpenBlock()` never folds it into `openLines`), so if `catchUpAndFinalize`
    /// (`HotBlockRasterizerStore.swift`) works, the sealed bitmap must be BYTE-IDENTICAL to the
    /// prior frame, not just the same `CGImage` instance. A pixel diff would mean the flash is a
    /// real rendering discontinuity, not a caching gap.
    func testSealedBlockWithNoNewContent_PixelIdenticalToLastHotFrame() async {
        let feed = makeStreamingFeed()
        var parser = IncrementalMarkdownParser()
        parser.append("First paragraph")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // The very first mount never synchronously rasterizes text (no general first-mount
        // rasterizer — see RenderCell.applyLayout's doc on the text branch), so a hot bitmap only
        // exists after at least one more append round routes through applyInPlaceBlockDiff's
        // hot-append path. This round is itself the FINAL content block0 will have — the round
        // after this one only appends the blank line, adding nothing to block0's own text.
        parser.append(", done growing")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()

        guard let hotBitmap = feed._debugPaintedBitmaps(at: 0).values.first else {
            return XCTFail("block0 must be painting something while still hot")
        }
        let hotPixels = rawPixels(of: hotBitmap)
        XCTAssertFalse(hotPixels.isEmpty, "Precondition: must be able to read the hot bitmap's pixels")

        // Pure seal signal: the blank line closes block0 but adds no characters TO block0. While
        // block0 is still the ONLY block, `applyInPlaceBlockDiff` keeps treating it as the trailing
        // (still-growing) block regardless of the PARSER's own frontier — see this function's doc:
        // `trailingIndex == newBlocks.count - 1` always, so a single-block item's sole block is
        // never eligible for `persist: true` until a real block AFTER it exists. So block0 is NOT
        // frozen yet here — this round is a zero-delta hot-append, not a freeze.
        parser.append("\n\n")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()

        // NOW a real second block exists — block0 stops being trailingIndex and becomes eligible
        // to freeze. This is the exact moment the user-reported flash happens: "the paragraph that
        // just closed redraws right as the next one starts."
        parser.append("Second paragraph starts")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        XCTAssertEqual(parser.frontier, 1, "Precondition: the blank line must have sealed exactly block0")

        let key0 = BlockKey(itemID: 0, index: 0)
        guard let sealedBitmap = feed.renderEnvironment.frozenBitmapStore.bitmap(for: key0) else {
            return XCTFail("block0 must be frozen into FrozenBitmapStore once the blank line seals it")
        }
        let sealedPixels = rawPixels(of: sealedBitmap)

        XCTAssertEqual(hotBitmap.width, sealedBitmap.width,
            "sealing with zero new visible content must not change the bitmap's pixel width")
        XCTAssertEqual(hotBitmap.height, sealedBitmap.height,
            "sealing with zero new visible content must not change the bitmap's pixel height")
        XCTAssertEqual(hotPixels, sealedPixels,
            "sealing a block whose visible text did NOT change must reuse pixel-identical bytes — "
            + "any diff here is a real rendering discontinuity (e.g. HotBlockMeasurer's incremental "
            + "measure disagreeing with a cold measure for the same text), not a cache-identity bug")
    }

    // MARK: - hotBlockRasterizeEnabled == false falls back to full rasterizeText per token (VelocityUI-xxf7)

    /// BenchmarkHost's `stream` scenario runs the identical token stream with
    /// `RenderEnvironment.hotBlockRasterizeEnabled` true (VelocityUI-x4q0's O(appended) path) and
    /// false (this bead's OFF side — the pre-x4q0 O(block) fallback) to report the win. This is
    /// the regression guard that OFF genuinely disengages the hot-append path rather than merely
    /// being ignored: growing the trailing block must route through the SAME
    /// `measureAndMaybeFreeze`/`rasterizeText` primitives every other volatile/sealed block uses,
    /// never `hotBlockRasterizerStore.append`.
    func testHotBlockRasterizeDisabled_TrailingBlockUsesFullRasterizeFallback_NeverHotAppend() async {
        let env = makeEnvironment(hotBlockRasterizeEnabled: false)
        let feed = makeStreamingFeed(environment: env)
        var parser = IncrementalMarkdownParser()
        parser.append("Hello")
        feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let hotAppendCountBefore = feed._blockDiffHotAppendCallCount
        let rasterizeCountBefore = feed._blockDiffRasterizeCallCount

        let tokens = [" world", " this", " is", " a", " streaming", " message"]
        for token in tokens {
            parser.append(token)
            feed.items = [StreamingMessage(id: 0, markdownParser: parser)]
            feed.layoutSubviews()
        }

        XCTAssertEqual(feed._blockDiffHotAppendCallCount, hotAppendCountBefore,
            "hotBlockRasterizeEnabled == false must never engage the O(appended) hot-append path")
        XCTAssertGreaterThan(feed._blockDiffRasterizeCallCount, rasterizeCountBefore,
            "hotBlockRasterizeEnabled == false must fall back to a full rasterizeText pass per token")
        XCTAssertNil(env.hotBlockRasterizerStore.finalize(BlockKey(itemID: 0, index: 0), expectedContentHash: 0),
            "the hot rasterizer store must stay empty for this key — OFF never populates it")

        await drainFeedWork(feed)
    }
}
#endif
