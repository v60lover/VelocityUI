// StreamingTextRenderingRegressionTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class StreamingTextRenderingRegressionTests: XCTestCase {

    private struct Message: Identifiable, Sendable {
        let id: Int
        var parser: IncrementalMarkdownParser
    }

    private func makeFeed(height: CGFloat = 812) -> FeedScrollView<Message> {
        let dimensionCache = DimensionCache()
        let videoPreparation = VideoPreparationActor()
        let environment = RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dimensionCache,
            imageActor: ImageActor(dimensionCache: dimensionCache),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPreparation),
            videoPreparation: videoPreparation,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore()
        )
        let feed = FeedScrollView<Message>(
            environment: environment,
            frame: CGRect(x: 0, y: 0, width: 375, height: height)
        )
        feed.cellBuilder = { message in
            VStackNode(alignment: .leading, spacing: 8) {
                message.parser.renderNodes
            }
        }
        return feed
    }

    private func waitUntil(
        _ feed: FeedScrollView<Message>,
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func pixelBytes(of image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return Data(bytes: data, count: width * height * 4)
    }

    func testFirstMountAndEveryTokenPaintImmediately_ThenFinalSealStaysVisible() async {
        let feed = makeFeed()
        var parser = IncrementalMarkdownParser()
        parser.append("Hello")
        feed.items = [Message(id: 0, parser: parser)]

        let firstMountPainted = await waitUntil(feed) {
            feed._debugPaintedBitmaps(at: 0).count == 1
        }
        XCTAssertTrue(firstMountPainted, "the first committed text layout must already have pixels")

        guard let firstBitmap = feed._debugPaintedBitmaps(at: 0).values.first,
              var previousPixels = pixelBytes(of: firstBitmap)
        else {
            return XCTFail("the first committed text layout must already have pixels")
        }
        var expectedContent = "Hello"
        for token in [" world", " from", " a", " normal", " streaming", " response"] {
            let hotAppendCount = feed._blockDiffHotAppendCallCount
            expectedContent += token
            parser.append(token)
            feed.items = [Message(id: 0, parser: parser)]
            feed.layoutSubviews()

            XCTAssertGreaterThan(feed._blockDiffHotAppendCallCount, hotAppendCount,
                "every token must traverse the synchronous hot-block update path")
            guard let fragment = feed._debugExtractFragmentsFromWorkingRange(at: 0)?.first,
                  case .text(let descriptor) = fragment.content
            else { return XCTFail("the updated text fragment must remain committed") }
            XCTAssertEqual(descriptor.content, expectedContent,
                "the committed fragment must contain the current token")

            guard let bitmap = feed._debugPaintedBitmaps(at: 0).values.first else {
                return XCTFail("every token update must leave a painted text bitmap")
            }
            guard let pixels = pixelBytes(of: bitmap) else {
                return XCTFail("every painted text bitmap must expose readable pixels")
            }
            XCTAssertNotEqual(pixels, previousPixels,
                "each token must produce a new visible frame instead of waiting for a later batch")
            previousPixels = pixels
        }

        parser.append("\n\n")
        feed.items = [Message(id: 0, parser: parser)]
        feed.layoutSubviews()
        XCTAssertEqual(feed._debugPaintedBitmaps(at: 0).count, 1,
            "sealing the final paragraph must not clear its text layer")

        feed.layoutSubviews()
        XCTAssertEqual(feed._debugPaintedBitmaps(at: 0).count, 1,
            "the completed response must remain visible during the next reconciliation")

        await drainFeedWork(feed)
    }

    func testScrollingWithinTallTextItemKeepsEveryActiveBlockPainted() async {
        let feed = makeFeed(height: 100)
        var parser = IncrementalMarkdownParser()
        for index in 0..<8 {
            let words = Array(repeating: "streaming paragraph \(index)", count: 5).joined(separator: " ")
            parser.append(words)
            if index < 7 { parser.append("\n\n") }
        }
        feed.items = [Message(id: 0, parser: parser)]

        let topRangePainted = await waitUntil(feed) {
            !feed._debugPaintedBitmaps(at: 0).isEmpty
        }
        XCTAssertTrue(topRangePainted, "the top block range must paint before scrolling")

        guard let frame = feed._debugResolvedFrame(at: 0) else {
            return XCTFail("the tall text item must have a resolved frame")
        }
        XCTAssertGreaterThan(frame.height, feed.bounds.height * 3,
            "the fixture must cross several block-residency windows")

        let topIDs = Set(feed._debugPaintedBitmaps(at: 0).keys)
        feed.contentOffset.y = max(0, frame.maxY - feed.bounds.height)
        feed.layoutSubviews()
        let bottomIDs = Set(feed._debugPaintedBitmaps(at: 0).keys)

        XCTAssertFalse(bottomIDs.isEmpty,
            "viewport reconciliation must restore cached text pixels synchronously")
        XCTAssertNotEqual(bottomIDs, topIDs,
            "scrolling must activate a different block range in the same cell")

        feed.contentOffset.y = 0
        feed.layoutSubviews()
        XCTAssertFalse(feed._debugPaintedBitmaps(at: 0).isEmpty,
            "scrolling back must not leave the text layers blank")

        await drainFeedWork(feed)
    }
}
#endif
