// CodeBlockRasterizerTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// VelocityUI-oz5q.4: color runs from a `SyntaxHighlighter` rasterize to a CGImage through the
/// existing NSTextLayoutManager pipeline (no CATextLayer), with zero-width raster gaps filled,
/// non-wrapping longest-line width, and measure/render parity within 1pt.
final class CodeBlockRasterizerTests: XCTestCase {
    private let font = VFontDescriptor(size: 20, weight: 0, family: "Menlo")
    private let theme = Theme.defaultLight

    // MARK: - makeCodeTextDescriptor: gapless, ordered partition of content

    func testDescriptorRunsExactlyPartitionContentWithNoGapsOrOverlaps() {
        let lines: [String] = ["let x = 1", "  return x"]
        let colorRuns = [
            LineColorRuns(runs: [
                ColorRun(range: 0..<3, tokenType: .keyword, color: theme.color(for: .keyword))
            ]),
            LineColorRuns(runs: [
                ColorRun(range: 2..<8, tokenType: .keyword, color: theme.color(for: .keyword))
            ])
        ]

        let descriptor = makeCodeTextDescriptor(lines: lines[...], colorRuns: colorRuns, font: font, theme: theme)
        let attrs = descriptor.attributedString

        XCTAssertEqual(descriptor.content, lines.joined(separator: "\n"))
        XCTAssertEqual(attrs.string, descriptor.content, "gap-filled runs must not drop or duplicate any character")
        XCTAssertEqual(attrs.length, descriptor.content.utf16.count)

        let totalRunLength = descriptor.runs.reduce(0) { $0 + $1.length }
        XCTAssertEqual(totalRunLength, descriptor.content.utf16.count, "runs must exactly partition content, no under/over-covering")
    }

    func testDescriptorUsesByClippingLineBreakMode() {
        let descriptor = makeCodeTextDescriptor(lines: ["one line"][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme)
        XCTAssertEqual(NSLineBreakMode(rawValue: descriptor.lineBreakMode), .byClipping)
    }

    func testMissingColorRunsEntryFallsBackToPlainForThatLine() {
        // colorRuns shorter than lines -- must not crash, missing lines fall back to plain.
        let lines = ["first", "second"]
        let descriptor = makeCodeTextDescriptor(lines: lines[...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme)
        XCTAssertEqual(descriptor.content, "first\nsecond")
        XCTAssertEqual(descriptor.runs.reduce(0) { $0 + $1.length }, descriptor.content.utf16.count)
    }

    // MARK: - rasterizeCodeBlock: measure/render parity, non-wrapping width, colors in the bitmap

    func testRasterizeCodeBlock_measuredHeightMatchesRenderedHeightWithin1pt() async {
        let lines = ["let aaaaa = 1", "let bbbbb = 2", "let ccccc = 3"]
        let colorRuns = lines.map { _ in LineColorRuns(runs: []) }
        let pool = TextMeasurementPool()

        let (image, size) = await rasterizeCodeBlock(
            lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, textPool: pool, scale: 2
        )

        guard let image else { return XCTFail("expected a non-nil raster for non-degenerate content") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)

        let renderedHeight = actualContentHeight(in: image) / 2 // undo scale
        XCTAssertLessThanOrEqual(
            renderedHeight, size.height + 1,
            "rendered ink height \(renderedHeight)pt overflowed measured \(size.height)pt by more than 1pt"
        )
    }

    func testRasterizeCodeBlock_widthEqualsLongestLineNotWrapped() async {
        let shortLine = "x"
        let longLine = String(repeating: "m", count: 80)
        let lines = [shortLine, longLine]
        let colorRuns = lines.map { _ in LineColorRuns(runs: []) }
        let pool = TextMeasurementPool()

        let (image, size) = await rasterizeCodeBlock(
            lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, textPool: pool, scale: 1
        )
        guard let image else { return XCTFail("expected a non-nil raster") }

        let soloDescriptor = makeCodeTextDescriptor(lines: [longLine][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme)
        let soloSize = TextMeasurementContext().measure(soloDescriptor, width: .greatestFiniteMagnitude)

        XCTAssertEqual(size.width, CGFloat(image.width), accuracy: 0.01,
                       "reported width must match the actual bitmap width")
        XCTAssertGreaterThan(size.width, soloSize.width,
                             "the bitmap must contain the longest line plus its container padding and ink guard")
        XCTAssertEqual(size.height, soloSize.height * 2, accuracy: 1,
                       "two source lines must remain two non-wrapping layout fragments")
    }

    func testRasterizeCodeBlock_preservesFinalGlyphAgainstTightRelayout() async {
        let line = String(repeating: "m", count: 48) + "W"
        let descriptor = makeCodeTextDescriptor(
            lines: [line][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme
        )
        let measuredSize = TextMeasurementContext().measure(descriptor, width: .greatestFiniteMagnitude)
        let scale: CGFloat = 2

        // This is the regression oracle: the old wrapper re-laid out at measuredSize.width,
        // making NSTextContainer's 5pt side padding clip the last glyph before drawing.
        let tightImage = rasterizeText(
            descriptor, layoutWidth: measuredSize.width, outputSize: measuredSize, scale: scale, inkGuard: 0
        )
        let expectedImage = rasterizeText(
            descriptor, layoutWidth: .greatestFiniteMagnitude, outputSize: measuredSize,
            scale: scale, inkGuard: codeInkRightGuard
        )
        guard let tightImage, let expectedImage else {
            return XCTFail("expected both tight and unbounded reference rasters")
        }
        let expectedRight = rightmostInkPixel(in: expectedImage)
        XCTAssertGreaterThan(
            expectedRight - rightmostInkPixel(in: tightImage), Int(scale.rounded()),
            "the fixture must expose the 5pt side-padding clipping regression"
        )

        let (image, size) = await rasterizeCodeBlock(
            lines: [line][...], colorRuns: [LineColorRuns(runs: [])], font: font,
            theme: theme, textPool: TextMeasurementPool(), scale: scale
        )
        guard let image else { return XCTFail("expected a sealed code raster") }

        XCTAssertEqual(image.width, expectedImage.width, "sealed raster must use the unbounded line layout")
        XCTAssertEqual(size.width, CGFloat(image.width) / scale, accuracy: 0.01,
                       "returned sealed width must match the actual bitmap width")
        XCTAssertGreaterThanOrEqual(
            rightmostInkPixel(in: image), expectedRight - 1,
            "the final glyph's ink must remain reachable at the right edge"
        )
        XCTAssertEqual(size.height, font.uiFont.lineHeight, accuracy: 1,
                       "a single code line must remain one non-wrapping fragment")
    }

    func testRasterizeCodeBlock_twoColorRunProducesTwoDistinctColors() async {
        let word1 = "aaaaa"
        let word2 = "bbbbb"
        let line = word1 + word2
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let colorRuns = [
            LineColorRuns(runs: [
                ColorRun(range: 0..<word1.utf16.count, tokenType: .keyword, color: red),
                ColorRun(range: word1.utf16.count..<line.utf16.count, tokenType: .string, color: blue)
            ])
        ]
        let pool = TextMeasurementPool()

        let (image, size) = await rasterizeCodeBlock(
            lines: [line][...], colorRuns: colorRuns, font: font, theme: theme, textPool: pool, scale: 1
        )
        guard let image else { return XCTFail("expected a non-nil raster") }

        // Scan a column band well inside each word, one full char-width away from the word
        // boundary -- a glyph's ink can extend past its advance box (e.g. italic-like overhang),
        // so sampling right at the midpoint risks picking up the neighboring word's antialiased
        // bleed instead of its own color.
        let charWidth = size.width / CGFloat(line.utf16.count)
        let leftRange = Int(charWidth)..<Int(charWidth * 3)
        let rightRange = Int(charWidth * 7)..<Int(size.width - charWidth)
        let leftInk = dominantInkColor(in: image, xRange: leftRange, yRange: 0..<Int(size.height))
        let rightInk = dominantInkColor(in: image, xRange: rightRange, yRange: 0..<Int(size.height))

        XCTAssertGreaterThan(leftInk.a, 0, "left word must have rendered ink")
        XCTAssertGreaterThan(rightInk.a, 0, "right word must have rendered ink")
        XCTAssertGreaterThan(leftInk.r, leftInk.b, "left word must sample closer to red")
        XCTAssertGreaterThan(rightInk.b, rightInk.r, "right word must sample closer to blue")
    }

    // MARK: - codeBlockBodyHeight: exact, synchronous background-height sizing (VelocityUI-oz5q.5)

    func testCodeBlockBodyHeight_matchesTextKitMeasuredHeightWithin1pt() async {
        let pool = TextMeasurementPool()
        for lineCount in [1, 2, 3, 5, 12] {
            let lines = (0..<lineCount).map { "let x\($0) = \($0)" }
            let colorRuns = lines.map { _ in LineColorRuns(runs: []) }

            let (_, measuredSize) = await rasterizeCodeBlock(
                lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, textPool: pool
            )
            let computedHeight = codeBlockBodyHeight(lineCount: lineCount, font: font)

            XCTAssertEqual(
                computedHeight, measuredSize.height, accuracy: 1,
                "line-count height for \(lineCount) lines must match TextKit's own measurement within 1pt"
            )
        }
    }

    func testCodeBlockBodyHeight_zeroLinesReturnsZero() {
        XCTAssertEqual(codeBlockBodyHeight(lineCount: 0, font: font), 0)
    }

    func testRasterizeCodeBlock_degenerateEmptyContentReturnsNilImageNotCrash() async {
        let pool = TextMeasurementPool()
        let (image, size) = await rasterizeCodeBlock(
            lines: [""][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme, textPool: pool
        )
        XCTAssertNil(image)
        XCTAssertEqual(size.width, 0)
    }

    // MARK: - rasterizeCodeBlockSync: same output as the async version (VelocityUI-yvjr)

    func testRasterizeCodeBlockSync_matchesAsyncVersion_sameSizeAndPixels() async {
        let lines = ["let aaaaa = 1", "let bbbbb = 2"]
        let colorRuns = [
            LineColorRuns(runs: [ColorRun(range: 0..<3, tokenType: .keyword, color: theme.color(for: .keyword))]),
            LineColorRuns(runs: [])
        ]
        let pool = TextMeasurementPool()

        let (asyncImage, asyncSize) = await rasterizeCodeBlock(
            lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, textPool: pool, scale: 2
        )
        let (syncImage, syncSize) = rasterizeCodeBlockSync(
            lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, scale: 2,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        guard let asyncImage, let syncImage else { return XCTFail("expected non-nil rasters") }
        XCTAssertEqual(asyncSize, syncSize)
        XCTAssertEqual(asyncImage.width, syncImage.width)
        XCTAssertEqual(asyncImage.height, syncImage.height)
    }

    func testRasterizeCodeBlockSync_widthEqualsLongestLineNotWrapped() {
        let shortLine = "x"
        let longLine = String(repeating: "m", count: 80)
        let lines = [shortLine, longLine]
        let colorRuns = lines.map { _ in LineColorRuns(runs: []) }

        let (image, size) = rasterizeCodeBlockSync(
            lines: lines[...], colorRuns: colorRuns, font: font, theme: theme, scale: 1,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        guard let image else { return XCTFail("expected a non-nil raster") }

        let soloDescriptor = makeCodeTextDescriptor(lines: [longLine][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme)
        let soloSize = TextMeasurementContext().measure(soloDescriptor, width: .greatestFiniteMagnitude)
        XCTAssertEqual(size.width, CGFloat(image.width), accuracy: 0.01)
        XCTAssertGreaterThan(size.width, soloSize.width)
        XCTAssertEqual(size.height, soloSize.height * 2, accuracy: 1)
    }

    func testRasterizeCodeBlockSync_preservesFinalGlyphAgainstTightRelayout() {
        let line = String(repeating: "m", count: 48) + "W"
        let descriptor = makeCodeTextDescriptor(
            lines: [line][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme
        )
        let measuredSize = TextMeasurementContext().measure(descriptor, width: .greatestFiniteMagnitude)
        let scale: CGFloat = 2
        let expectedImage = rasterizeText(
            descriptor, layoutWidth: .greatestFiniteMagnitude, outputSize: measuredSize,
            scale: scale, inkGuard: codeInkRightGuard
        )
        guard let expectedImage else { return XCTFail("expected an unbounded reference raster") }

        let (image, size) = rasterizeCodeBlockSync(
            lines: [line][...], colorRuns: [LineColorRuns(runs: [])], font: font,
            theme: theme, scale: scale,
            measure: { descriptor, width in TextMeasurementContext().measure(descriptor, width: width) }
        )
        guard let image else { return XCTFail("expected a sealed code raster") }

        XCTAssertEqual(image.width, expectedImage.width, "sync sealed raster must use the unbounded line layout")
        XCTAssertEqual(size.width, CGFloat(image.width) / scale, accuracy: 0.01,
                       "sync returned width must match the actual bitmap width")
        XCTAssertGreaterThanOrEqual(
            rightmostInkPixel(in: image), rightmostInkPixel(in: expectedImage) - 1,
            "the sync path must preserve the final glyph's ink"
        )
        XCTAssertEqual(size.height, font.uiFont.lineHeight, accuracy: 1,
                       "the sync code layout must remain one non-wrapping fragment")
    }

    func testRasterizeCodeBlockSync_degenerateEmptyContentReturnsNilImageNotCrash() {
        let (image, size) = rasterizeCodeBlockSync(
            lines: [""][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: theme,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        XCTAssertNil(image)
        XCTAssertEqual(size.width, 0)
    }

    // MARK: - rasterizeCodeBlockBackground / codeBlockBackgroundContentsCenter (VelocityUI-oz5q.5)

    func testRasterizeCodeBlockBackground_cornerPixelIsTransparent_centerPixelIsOpaqueFill() {
        let color = VColorDescriptor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        guard let image = rasterizeCodeBlockBackground(cornerRadius: 12, color: color, scale: 1) else {
            return XCTFail("expected a non-nil raster for a positive corner radius")
        }
        XCTAssertEqual(image.width, 25, "template side must be 2*cornerRadius+1")
        XCTAssertEqual(image.height, 25)

        let corner = pixelColor(in: image, x: 0, y: 0)
        XCTAssertEqual(corner.a, 0, "the clipped-out corner must be fully transparent -- pre-rounded, not a square")

        let center = pixelColor(in: image, x: 12, y: 12)
        XCTAssertGreaterThan(center.a, 200, "the center must be opaque fill")
        XCTAssertGreaterThan(center.b, center.r, "center pixel must sample as the fill color (blue channel dominant)")
    }

    func testRasterizeCodeBlockBackground_zeroCornerRadius_isFullyOpaqueNoClip() {
        let color = VColorDescriptor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let image = rasterizeCodeBlockBackground(cornerRadius: 0, color: color, scale: 1) else {
            return XCTFail("expected a non-nil raster for zero corner radius")
        }
        let corner = pixelColor(in: image, x: 0, y: 0)
        XCTAssertGreaterThan(corner.a, 200, "zero corner radius must not clip any pixel, including the corner")
    }

    func testCodeBlockBackgroundContentsCenter_matchesRasterizeCodeBlockBackgroundTemplateSize() {
        let cornerRadius: CGFloat = 12
        let scale: CGFloat = 2
        guard let image = rasterizeCodeBlockBackground(
            cornerRadius: cornerRadius, color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1), scale: scale
        ) else { return XCTFail("expected a non-nil raster") }

        let side = CGFloat(image.width)
        let contentsCenter = codeBlockBackgroundContentsCenter(cornerRadius: cornerRadius, scale: scale)

        let radiusPixels = (cornerRadius * scale).rounded()
        XCTAssertEqual(contentsCenter.origin.x, radiusPixels / side, accuracy: 0.001)
        XCTAssertEqual(contentsCenter.origin.y, radiusPixels / side, accuracy: 0.001)
        XCTAssertEqual(contentsCenter.width, 1 / side, accuracy: 0.001)
        XCTAssertEqual(contentsCenter.height, 1 / side, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func pixelColor(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return (0, 0, 0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (0, 0, 0, 0) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let flippedY = h - 1 - y // CGContext draws bottom-up
        let offset = (flippedY * w + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// Mirrors MultiRunTextDescriptorTests' helper of the same shape.
    private func actualContentHeight(in image: CGImage) -> CGFloat {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in 0..<w {
                if bytes[(row * w + col) * 4 + 3] > 0 { return CGFloat(row + 1) }
            }
        }
        return 0
    }

    /// The most-opaque pixel within `xRange`/`yRange` -- robust against anti-aliased glyph edges,
    /// where any single fixed coordinate might land on background instead of a stroke.
    private func dominantInkColor(
        in image: CGImage, xRange: Range<Int>, yRange: Range<Int>
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return (0, 0, 0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (0, 0, 0, 0) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var best: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (0, 0, 0, 0)
        for row in yRange.clamped(to: 0..<h) {
            let flippedY = h - 1 - row // CGContext draws bottom-up
            for col in xRange.clamped(to: 0..<w) {
                let offset = (flippedY * w + col) * 4
                let alpha = bytes[offset + 3]
                if alpha > best.a {
                    best = (bytes[offset], bytes[offset + 1], bytes[offset + 2], alpha)
                }
            }
        }
        return best
    }

    private func rightmostInkPixel(in image: CGImage, alphaThreshold: UInt8 = 8) -> Int {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return -1 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for column in stride(from: width - 1, through: 0, by: -1) {
            for row in 0..<height where bytes[(row * width + column) * 4 + 3] >= alphaThreshold {
                return column
            }
        }
        return -1
    }
}
#endif
