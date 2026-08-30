#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

@MainActor
final class StreamDatasetHeadingDiagnosticTests: XCTestCase {
    private struct Message: Identifiable, Sendable {
        let id: Int
        var parser: IncrementalMarkdownParser
    }

    private func makeFeed(controller: StreamingMarkdownController) -> FeedScrollView<Message> {
        let dimensions = DimensionCache()
        let videoPreparation = VideoPreparationActor()
        let environment = RenderEnvironment(
            textPool: TextMeasurementPool(), layoutCache: LayoutCache(),
            dimensionCache: dimensions, imageActor: ImageActor(dimensionCache: dimensions),
            gifActor: GIFActor(), videoController: VideoController(videoPreparation: videoPreparation),
            videoPreparation: videoPreparation, frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(), hotCodeStreamStore: HotCodeStreamStore()
        )
        let feed = FeedScrollView<Message>(environment: environment, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        feed.cellBuilder = { _ in
            let nodes = StreamDataset.interleavedRenderNodes(
                textNodes: controller.renderNodes,
                frontier: controller.parser.frontier,
                includeInterleavedBlocks: true
            )
            return VStackNode(alignment: .leading, spacing: 8) { nodes }
        }
        return feed
    }

    private func publish(_ controller: StreamingMarkdownController, to feed: FeedScrollView<Message>) {
        feed.items = [Message(id: 0, parser: controller.parser)]
        feed.layoutSubviews()
    }

    private func waitForHeadingCount(_ count: Int, in feed: FeedScrollView<Message>) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            if feed._debugExtractFragmentsFromWorkingRange(at: 0)?.count == count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testExactOpeningStreamDatasetChunksAllocateBothHeadings() async throws {
        var theme = MarkdownTheme.default
        theme.code = VFontDescriptor(size: 13, weight: VFontDescriptor.regularWeight)
        let controller = StreamingMarkdownController(theme: theme)
        let feed = makeFeed(controller: controller)

        publish(controller, to: feed)
        controller.append("Streaming benchmark response\n")
        publish(controller, to: feed)
        try? await Task.sleep(for: .milliseconds(50))
        controller.append("===\n")
        publish(controller, to: feed)
        try? await Task.sleep(for: .milliseconds(50))
        controller.append("\n")
        publish(controller, to: feed)
        try? await Task.sleep(for: .milliseconds(50))
        controller.append("## Why token-by-token rendering doesn't jank\n\n")
        publish(controller, to: feed)

        await waitForHeadingCount(2, in: feed)
        let fragments = try XCTUnwrap(feed._debugExtractFragmentsFromWorkingRange(at: 0))
        XCTAssertEqual(fragments.count, 2)
        var expectedTotal: CGFloat = 8
        for (index, fragment) in fragments.enumerated() {
            guard case .text(let descriptor) = fragment.content else { return XCTFail("Expected heading text") }
            let cold = TextMeasurementContext().measure(descriptor, width: 390)
            print("STREAMDATA_HEADING index=\(index) text=\(descriptor.content) cold=\(cold.height) fragment=\(fragment.frame.height)")
            XCTAssertEqual(fragment.frame.height, cold.height, accuracy: 1)
            expectedTotal += cold.height
        }
        let cellHeight = try XCTUnwrap(feed._debugResolvedFrame(at: 0)).height
        print("STREAMDATA_CELL expected=\(expectedTotal) actual=\(cellHeight) contentSize=\(feed.contentSize.height)")
        XCTAssertEqual(cellHeight, expectedTotal, accuracy: 1)
        XCTAssertEqual(feed.contentSize.height, expectedTotal, accuracy: 1)
    }

    private func pixels(_ image: CGImage) -> Data? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        return Data(bytes: data, count: image.width * image.height * 4)
    }

    func testRealStreamDatasetSingleAppendHeadingBitmapIsComplete() async throws {
        var theme = MarkdownTheme.default
        theme.code = VFontDescriptor(size: 13, weight: VFontDescriptor.regularWeight)
        let controller = StreamingMarkdownController(theme: theme)
        let feed = makeFeed(controller: controller)
        publish(controller, to: feed)

        for token in StreamDataset.tokens() {
            controller.append(token)
            publish(controller, to: feed)
            feed.contentOffset.y = max(0, feed.contentSize.height - feed.bounds.height)
            feed.layoutSubviews()
            try? await Task.sleep(for: .milliseconds(50))
            if token == "## A single append, traced\n\n" { break }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var target: Fragment?
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            target = feed._debugExtractFragmentsFromWorkingRange(at: 0)?.first { fragment in
                guard case .text(let descriptor) = fragment.content else { return false }
                return descriptor.content == "A single append, traced"
            }
            if target != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let heading = try XCTUnwrap(target)
        guard case .text(let descriptor) = heading.content else { return XCTFail("Expected single-append heading text") }
        feed.contentOffset.y = max(0, heading.frame.minY - 100)
        feed.layoutSubviews()

        let cold = TextMeasurementContext().measure(descriptor, width: 390)
        let painted = try XCTUnwrap(feed._debugPaintedBitmaps(at: 0)[heading.id])
        let scale = max(1, feed.traitCollection.displayScale)
        // Layout must happen at the same width the height was measured at (390), not the
        // tight `cold` width -- rasterizing narrower than measurement is exactly the bug
        // under test (extra wrap pushed below the canvas, tail clipped).
        let expected = try XCTUnwrap(rasterizeText(descriptor, layoutWidth: 390, outputSize: cold, scale: scale))
        print("SINGLE_APPEND_DIAGNOSTIC text=\(descriptor.content) frame=\(heading.frame) cold=\(cold) paintedPixels=\(painted.width)x\(painted.height) expectedPixels=\(expected.width)x\(expected.height)")

        XCTAssertEqual(heading.frame.width, cold.width, accuracy: 1)
        XCTAssertEqual(heading.frame.height, cold.height, accuracy: 1)
        XCTAssertEqual(painted.width, expected.width)
        XCTAssertEqual(painted.height, expected.height)
        XCTAssertEqual(pixels(painted), pixels(expected), "Single-append bitmap must contain the full cold-rendered heading")
    }

    /// Regression test for the layout-width/output-width split in `rasterizeText`. Rasterizing
    /// with `layoutWidth` pinned to the *tight* measured width (the old, buggy call shape) can
    /// re-wrap the text to an extra line that a canvas sized from the *original* measured
    /// height doesn't have room for -- that extra line silently clips. Rasterizing with
    /// `layoutWidth` pinned to the width the height was actually measured at (the fix) can't
    /// re-wrap, so nothing clips.
    func testNarrowLayoutWidthCanClipWhileFullLayoutWidthMatchesMeasuredHeight() throws {
        let font = VFontDescriptor(size: 22, weight: VFontDescriptor.boldWeight)
        let text = "Trade-offs when you stream responses to the screen"
        let descriptor = TextDescriptor(
            content: text,
            font: font,
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 0,
            appearanceHash: 0
        )

        let fullWidth: CGFloat = 390
        let ctx = TextMeasurementContext()
        let cold = ctx.measure(descriptor, width: fullWidth)
        let scale: CGFloat = 3

        // Fixed call shape: layout happens at the same width the height was measured at, so
        // the wrap TextKit produces here is guaranteed identical to the wrap `cold.height`
        // already accounts for -- nothing can clip.
        let fullLayoutBitmap = try XCTUnwrap(
            rasterizeText(descriptor, layoutWidth: fullWidth, outputSize: cold, scale: scale)
        )
        // The ink guard makes the canvas a hair wider than the tight advance, so width is a
        // floor (>=), not an exact match; height is the measured height to the pixel.
        XCTAssertGreaterThanOrEqual(fullLayoutBitmap.width, Int((cold.width * scale).rounded()))
        XCTAssertEqual(fullLayoutBitmap.height, Int((cold.height * scale).rounded()))

        // Old, buggy call shape: layout happens at the *tight* measured width instead of the
        // width used for measurement -- exactly what `TextRasteriser`'s old single-parameter
        // `rasterizeText(_:size:scale:)` did when callers passed the tight fragment frame for
        // both layout and canvas.
        let narrowLayoutBitmap = try XCTUnwrap(
            rasterizeText(descriptor, layoutWidth: cold.width, outputSize: cold, scale: scale)
        )

        // Does the narrow width actually re-wrap this text to something taller than `cold`
        // reports? If so, the narrow-layout bitmap above -- canvas capped at `cold.height` --
        // is exactly the clip bug: real content exists below the canvas.
        let narrowMeasured = ctx.measure(descriptor, width: cold.width)
        print(
            "LAYOUT_WIDTH_SPLIT cold=\(cold) narrowMeasuredAtColdWidth=\(narrowMeasured) "
            + "fullBitmap=\(fullLayoutBitmap.width)x\(fullLayoutBitmap.height) "
            + "narrowBitmap=\(narrowLayoutBitmap.width)x\(narrowLayoutBitmap.height)"
        )
        if narrowMeasured.height > cold.height {
            XCTAssertNotEqual(
                pixels(narrowLayoutBitmap), pixels(fullLayoutBitmap),
                "Narrow layoutWidth re-wraps this text to a taller layout than `cold.height` "
                + "provides room for -- its canvas should visibly differ (clipped) from the "
                + "full-width layout's canvas."
            )
        }
    }
}
#endif
