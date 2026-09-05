// BlockquoteRenderingTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// VelocityUI-i1xx.1: a blockquote must render with a visible left bar, indented text, and a
/// muted color, all baked into the raster (no CALayer cornerRadius/masksToBounds), with inline
/// emphasis inside the quote still applying.
final class BlockquoteRenderingTests: XCTestCase {

    // MARK: - Decoration data: blockquote differs from a plain paragraph

    func testBlockquoteDecoration_HasBarAndMutedColor_ParagraphHasNeither() {
        let quoteDecoration = IncrementalMarkdownParser.textDecoration(for: .blockquote)
        let paragraphDecoration = IncrementalMarkdownParser.textDecoration(for: .paragraph)

        XCTAssertNotNil(quoteDecoration.barColor, "a blockquote must draw a left bar")
        XCTAssertGreaterThan(quoteDecoration.barWidth, 0)
        XCTAssertNil(paragraphDecoration.barColor, "a plain paragraph must not draw a bar")

        XCTAssertNotEqual(quoteDecoration.color, VColorDescriptor.primary, "blockquote text must be muted, not primary")
        XCTAssertNotEqual(quoteDecoration.color, paragraphDecoration.color, "blockquote text must read as distinct from a paragraph")
    }

    // MARK: - End to end through the real parser: blockList's TextDescriptor carries the decoration

    func testBlockquote_BlockListDescriptor_CarriesLeadingBarAndMutedRunColor() {
        var parser = IncrementalMarkdownParser()
        parser.append("> quoted text\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("blockquote must render as .text")
        }

        XCTAssertNotNil(descriptor.leadingBarColor)
        XCTAssertGreaterThan(descriptor.leadingBarWidth, 0)
        XCTAssertFalse(descriptor.runs.isEmpty, "blockquote text always tokenizes to at least one run")
        XCTAssertEqual(descriptor.runs[0].color, IncrementalMarkdownParser.textDecoration(for: .blockquote).color)
    }

    /// Inline bold inside a blockquote must still resolve to the bold weight — the muted base
    /// color must not swallow emphasis.
    func testBlockquote_InlineBoldInsideQuote_StillRendersBoldWeight() {
        var parser = IncrementalMarkdownParser()
        parser.append("> plain **bold** plain\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("blockquote must render as .text")
        }

        let boldRun = descriptor.runs.first { $0.font.weight == VFontDescriptor.boldWeight }
        XCTAssertNotNil(boldRun, "bold emphasis inside a blockquote must still produce a bold-weight run")
    }

    // MARK: - Raster: the bar is actually painted into the bitmap, and text starts past the gap

    /// Drives the real parser output through `rasterizeText` (same call `RenderPipeline` makes)
    /// and inspects raw pixels: catches the invariant a data-only assertion can't -- that the bar
    /// is drawn INTO the raster (not a separate CALayer), and that it survives to the same bitmap
    /// the text is painted into.
    func testBlockquote_Raster_PaintsOpaqueBarInReservedLeftColumn() {
        var parser = IncrementalMarkdownParser()
        parser.append("> quoted text\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("blockquote must render as .text")
        }
        guard let barColor = descriptor.leadingBarColor else {
            return XCTFail("blockquote descriptor must carry a leadingBarColor")
        }

        let measureCtx = TextMeasurementContext()
        let measured = measureCtx.measure(descriptor, width: 400)
        XCTAssertGreaterThan(measured.height, 0)

        guard let image = rasterizeText(descriptor, layoutWidth: 400, outputSize: measured, scale: 1) else {
            XCTFail("rasterizeText returned nil for a blockquote descriptor"); return
        }

        // Sample one pixel column inside the bar's reserved width, a couple points down from the
        // top so we're clear of any top-edge antialiasing.
        let barPixel = pixelColor(in: image, x: 1, y: 2)
        XCTAssertNotNil(barPixel, "the bar column must be painted, not left transparent")
        if let barPixel {
            XCTAssertEqual(barPixel.alpha, 1, accuracy: 0.05)
            XCTAssertEqual(barPixel.red, barColor.red, accuracy: 0.05)
            XCTAssertEqual(barPixel.green, barColor.green, accuracy: 0.05)
            XCTAssertEqual(barPixel.blue, barColor.blue, accuracy: 0.05)
        }

        // A plain paragraph at the same x/y has nothing painted there -- proves the bar is
        // blockquote-specific, not a universal left-edge fill every text raster now carries.
        var plainParser = IncrementalMarkdownParser()
        plainParser.append("quoted text\n\n")
        let plainBlocks = plainParser.blockList(itemID: "msg", width: 400)
        guard case .text(let plainDescriptor) = plainBlocks[0].fragment.content else {
            return XCTFail("paragraph must render as .text")
        }
        XCTAssertNil(plainDescriptor.leadingBarColor)
        let plainMeasured = measureCtx.measure(plainDescriptor, width: 400)
        guard let plainImage = rasterizeText(plainDescriptor, layoutWidth: 400, outputSize: plainMeasured, scale: 1) else {
            XCTFail("rasterizeText returned nil for a paragraph descriptor"); return
        }
        let plainPixel = pixelColor(in: plainImage, x: 1, y: 2)
        XCTAssertTrue(plainPixel == nil || plainPixel!.alpha < 0.05, "a plain paragraph must not paint a bar in its left column")
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
