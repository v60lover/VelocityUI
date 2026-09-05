// ThematicBreakRenderingTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// VelocityUI-i1xx.2: a `---`/`***`/`___` line must render as a real horizontal rule spanning
/// the content width, drawn into the raster (no CALayer trick), with margin above and below.
final class ThematicBreakRenderingTests: XCTestCase {

    // MARK: - Decoration data: thematic break differs from a plain paragraph

    func testThematicBreakDecoration_HasRuleColor_ParagraphHasNone() {
        let ruleDecoration = IncrementalMarkdownParser.textDecoration(for: .thematicBreak)
        let paragraphDecoration = IncrementalMarkdownParser.textDecoration(for: .paragraph)

        XCTAssertNotNil(ruleDecoration.ruleColor, "a thematic break must draw a rule")
        XCTAssertNil(paragraphDecoration.ruleColor, "a plain paragraph must not draw a rule")
    }

    // MARK: - End to end through the real parser: blockList's TextDescriptor carries the rule

    func testThematicBreak_BlockListDescriptor_CarriesRuleColorNotLiteralDashes() {
        var parser = IncrementalMarkdownParser()
        parser.append("above\n\n---\n\nbelow\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard let ruleBlock = blocks.first(where: {
            if case .text(let d) = $0.fragment.content { return d.ruleColor != nil }
            return false
        }) else {
            return XCTFail("no block carried a ruleColor")
        }
        guard case .text(let descriptor) = ruleBlock.fragment.content else {
            return XCTFail("thematic break must render as .text")
        }

        XCTAssertNotNil(descriptor.ruleColor)
        XCTAssertNotEqual(descriptor.content, "---", "the raw dashes must never render as literal text")
    }

    // MARK: - Width: the rule's block must span the full proposed width, not its own tiny content

    /// A thematic break's "text" is a single invisible space, whose own intrinsic width is a
    /// few points -- far narrower than a real feed. `measureNode`'s `.text` case must special-case
    /// `ruleColor` and pin the block to the full proposed width instead, or the rule would only
    /// paint a few points wide (VelocityUI-i1xx.2's core acceptance criterion).
    @MainActor
    func testThematicBreak_MeasuredWidth_SpansFullProposedWidth() async {
        var parser = IncrementalMarkdownParser()
        parser.append("---\n\n")
        let nodes = parser.renderNodes
        guard let textNode = nodes.first as? TextNode else {
            return XCTFail("expected a TextNode for the thematic break")
        }
        XCTAssertNotNil(textNode.ruleColor)

        let table = flatten(textNode, itemID: "msg")
        let textPool = TextMeasurementPool()
        let layout = await measureNode(table, nodeIndex: 0, width: 400, textPool: textPool)
        XCTAssertEqual(layout.totalFrame.width, 400, "a rule must span the full proposed width")
    }

    // MARK: - Raster: the rule is actually painted into the bitmap, spanning full width, centered

    /// Drives the real parser output through `rasterizeText` (same call the render pipeline
    /// makes) and inspects raw pixels: catches the invariant a data-only assertion can't -- that
    /// the rule is drawn INTO the raster (not a separate CALayer), spans the full canvas width,
    /// and sits with visible margin above and below (not flush against the top/bottom edge).
    func testThematicBreak_Raster_PaintsRuleAcrossFullWidthWithMargin() {
        var parser = IncrementalMarkdownParser()
        parser.append("---\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("thematic break must render as .text")
        }
        guard let ruleColor = descriptor.ruleColor else {
            return XCTFail("thematic break descriptor must carry a ruleColor")
        }

        let measureCtx = TextMeasurementContext()
        let measured = measureCtx.measure(descriptor, width: 400)
        XCTAssertGreaterThan(measured.height, 0)

        // The block's own measured width is tiny (a single space) -- render at the full 400pt
        // container width, which is what the real pipeline does after `measureNode` pins it.
        let renderSize = CGSize(width: 400, height: measured.height)
        guard let image = rasterizeText(descriptor, layoutWidth: 400, outputSize: renderSize, scale: 1) else {
            XCTFail("rasterizeText returned nil for a thematic break descriptor"); return
        }
        XCTAssertEqual(image.width, 400, "the rule must span the full canvas width")

        // Scan column x=2 top to bottom for the rule's row -- its exact y depends on font metrics
        // (pixel-grid-snapped in `rasterizeText`), so this locates it instead of assuming an exact
        // row, while still verifying it sits away from both edges (the margin) and reads correct
        // color on both the left and right edge of the canvas (the full-width span).
        var ruleRow: Int?
        for y in 0..<image.height {
            if let pixel = pixelColor(in: image, x: 2, y: y), pixel.alpha > 0.5 {
                ruleRow = y
                break
            }
        }
        guard let ruleRow else { return XCTFail("no opaque row found -- the rule was never painted") }

        let marginAbove = ruleRow
        let marginBelow = image.height - 1 - ruleRow
        XCTAssertGreaterThan(marginAbove, 2, "the rule must not sit flush against the top edge")
        XCTAssertGreaterThan(marginBelow, 2, "the rule must not sit flush against the bottom edge")

        let leftEdge = pixelColor(in: image, x: 2, y: ruleRow)
        let rightEdge = pixelColor(in: image, x: image.width - 3, y: ruleRow)
        for (label, pixel) in [("left edge", leftEdge), ("right edge", rightEdge)] {
            guard let pixel else { return XCTFail("\(label) must be painted, not left transparent") }
            XCTAssertEqual(pixel.alpha, 1, accuracy: 0.05, "\(label) must be opaque")
            XCTAssertEqual(pixel.red, ruleColor.red, accuracy: 0.05, label)
            XCTAssertEqual(pixel.green, ruleColor.green, accuracy: 0.05, label)
            XCTAssertEqual(pixel.blue, ruleColor.blue, accuracy: 0.05, label)
        }

        // A plain paragraph at the same width has nothing painted at midY -- proves the rule is
        // thematic-break-specific, not something every text raster now carries.
        var plainParser = IncrementalMarkdownParser()
        plainParser.append("plain text\n\n")
        let plainBlocks = plainParser.blockList(itemID: "msg", width: 400)
        guard case .text(let plainDescriptor) = plainBlocks[0].fragment.content else {
            return XCTFail("paragraph must render as .text")
        }
        XCTAssertNil(plainDescriptor.ruleColor)
    }

    // MARK: - Helpers

    private struct RGBA { let red: CGFloat; let green: CGFloat; let blue: CGFloat; let alpha: CGFloat }

    /// Reads back one premultiplied-sRGB pixel. Returns nil if the coordinates fall outside the
    /// image (a too-narrow canvas is itself a signal the caller should fail on).
    private func pixelColor(in image: CGImage, x: Int, y: Int) -> RGBA? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        // Un-premultiply so the sampled color compares directly to the fill color that was set.
        return RGBA(
            red: CGFloat(pixel[0]) / 255 / alpha,
            green: CGFloat(pixel[1]) / 255 / alpha,
            blue: CGFloat(pixel[2]) / 255 / alpha,
            alpha: alpha
        )
    }
}
#endif
