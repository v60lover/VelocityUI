#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Regression for the "scroll down to a sealed code block, see only its background + header, no
/// code" bug. The trigger is a single tall streaming message (one always-mounted cell): a code
/// block that seals *below the fold* is never in the viewport while it streams, so its body is
/// never mounted. Scrolling to it later goes through the *kept-cell* branch of
/// `updateVisibleCells` (FeedScrollView+Scroll.swift), which calls
/// `updateBlockViewport(viewportInCell:synchronousContent:)` -- the overload that defaults
/// `codeBodyContent` to `[:]`. So the body fragment mounts with an empty chunk list and paints
/// nothing, while the background (drawn inline) and header (a normal text bitmap) still appear.
@MainActor
final class CodeBodyScrolledIntoViewTests: XCTestCase {
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
            VStackNode(alignment: .leading, spacing: 8) { controller.renderNodes }
        }
        return feed
    }

    /// Publish the current parser state and lay out, without moving the viewport off the top.
    private func publishAtTop(_ controller: StreamingMarkdownController, to feed: FeedScrollView<Message>) {
        feed.items = [Message(id: 0, parser: controller.parser)]
        feed.contentOffset.y = 0
        feed.layoutSubviews()
    }

    /// The `.body`-role code fragment for item 0, or nil if not laid out yet.
    private func bodyFragment(in feed: FeedScrollView<Message>) -> Fragment? {
        feed._debugExtractFragmentsFromWorkingRange(at: 0)?.first { fragment in
            guard case .text(let descriptor) = fragment.content else { return false }
            if case .body = descriptor.codeBlockRole { return true }
            return false
        }
    }

    func testCodeBodyPaintsWhenScrolledIntoViewInsideAnAlreadyMountedCell() async throws {
        var theme = MarkdownTheme.default
        theme.code = VFontDescriptor(size: 13, weight: VFontDescriptor.regularWeight)
        let controller = StreamingMarkdownController(theme: theme)
        let feed = makeFeed(controller: controller)
        publishAtTop(controller, to: feed)

        // 1. Enough prose to push everything after it clear of the working range (viewport plus
        //    its ~one-screen prefetch band below the fold), so the code block streams and seals
        //    entirely out of range -- never mounted, never painted -- until it is scrolled to.
        for paragraph in 0..<40 {
            controller.append("This is prose paragraph number \(paragraph) explaining why streaming rendering must never jank.\n\n")
            publishAtTop(controller, to: feed)
            try? await Task.sleep(for: .milliseconds(5))
        }

        // 2. A fenced Swift code block, streamed line by line while still at the top.
        controller.append("```swift\n")
        publishAtTop(controller, to: feed)
        for line in 0..<12 {
            controller.append("let value\(line) = compute(\(line)) + offset // streamed line \(line)\n")
            publishAtTop(controller, to: feed)
            try? await Task.sleep(for: .milliseconds(5))
        }
        controller.append("```\n\n")
        publishAtTop(controller, to: feed)

        // 3. Trailing prose after the fence -- guarantees the code block is sealed and is no
        //    longer the trailing hot block.
        controller.append("And this paragraph comes after the code block, sealing it.\n\n")
        publishAtTop(controller, to: feed)

        // Let any async colorization / finalize delivery settle while still at the top.
        for _ in 0..<20 {
            publishAtTop(controller, to: feed)
            try? await Task.sleep(for: .milliseconds(20))
        }

        // The code body must exist in layout and must have been offscreen (below the fold) the
        // whole time -- otherwise the test isn't exercising the scroll-into-view path.
        let body = try XCTUnwrap(bodyFragment(in: feed), "Expected a .body code fragment in the laid-out item")
        XCTAssertGreaterThan(body.frame.minY, feed.bounds.height,
                             "Precondition: code body must start below the fold so it was never mounted while streaming")
        XCTAssertFalse(feed._debugPaintedBitmaps(at: 0).keys.contains(body.id),
                       "Precondition: code body must not be painted while it is still offscreen at the top")

        // Now scroll down so the code body enters the viewport of the already-mounted cell.
        let maxOffset = max(0, feed.contentSize.height - feed.bounds.height)
        feed.contentOffset.y = min(maxOffset, max(0, body.frame.minY - 200))
        feed.layoutSubviews()

        // The card's chrome parts still paint...
        let nodeIndex = body.id
        let painted = feed._debugPaintedBitmaps(at: 0)
        XCTAssertNotNil(painted[codeBackgroundFragmentID(nodeIndex: nodeIndex)],
                        "Background should paint (drawn inline at mount)")
        XCTAssertNotNil(painted[codeHeaderFragmentID(nodeIndex: nodeIndex)],
                        "Header should paint (normal text bitmap)")

        // ...but the BODY must paint too. With the bug, this is the missing piece: the kept-cell
        // scroll branch never supplies codeBodyContent, so the body mounts with an empty chunk
        // list and this assertion fails.
        XCTAssertNotNil(painted[body.id],
                        "Code body must paint after scrolling it into view inside an already-mounted cell")
    }
}
#endif
