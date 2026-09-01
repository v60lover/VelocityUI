// TableRasterizerTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// VelocityUI-8ge8.4: table rasterization produces a CGImage with visible grid, correctly placed
/// cell text, bold header rendering, rounded corners via CGContext clip (never CALayer), BGRA8888
/// premultiplied output, and reported dimensions equal to Σ column widths/row heights + gridlines.
///
/// | # | Invariant being verified | Assertion |
/// |---|---|---|
/// | 1 | Grid lines are visible (both vertical divider and horizontal divider render with ink) | Sample pixel at known divider x/y coordinate (mid-line position) and assert opaque, matches gridColor |
/// | 2 | Cell text placed correctly — ink stays inside cell's own reserved region, not bled into adjacent row/column | Build 2-row, 1-column layout with distinct short strings ("A", "B"); assert each row's ink present within own y-range, absent in other row's y-range |
/// | 3 | Header row (bold font) actually rasterizes — not silently skipped | Assert ink (alpha > 0) present within header row's reserved band |
/// | 4 | Corners rounded via CGContext clip, never CALayer | Pixel at (0,0) has alpha 0 (clipped); with cornerRadius: 0, same corner is opaque |
/// | 5 | Output is BGRA8888 premultiplied | isBGRA8888(image) returns true |
/// | 6 | Reported content width/height equals Σ column widths/row heights + gridlines | size.width == Σ columnWidths + (columnCount+1)*gridLineWidth; size.height == Σ rowHeights + (rowCount+1)*gridLineWidth |
/// | 7 | No glyph clipping on bold header's trailing glyph (codeInkRightGuard regression) | Compare rightmostInkPixel between table image and reference raster; table's right edge >= reference's - 1 pixel |
/// | 8 | Degenerate empty layout does not crash, returns nil/zero | Call with empty ResolvedTableLayout(rows: [], ...), assert image == nil, size == .zero |
final class TableRasterizerTests: XCTestCase {
    private let gridColor = VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
    private let backgroundColor = VColorDescriptor(red: 1, green: 1, blue: 1, alpha: 1)

    // MARK: - Test 1: Grid lines are visible

    func testGridLinesAreVisible_verticalDivider() {
        let cells: [[TextDescriptor]] = [
            [makeCell("A"), makeCell("B")]
        ]
        let columnWidths: [CGFloat] = [80, 120]
        let alignments: [TableColumnAlignment] = [.left, .left]
        let gridLineWidth: CGFloat = 1

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: gridLineWidth,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster for non-degenerate content")
        }

        // Vertical divider between columns: x = columnWidths[0] + gridLineWidth/2
        let verticalDividerX = Int((columnWidths[0] + gridLineWidth / 2).rounded())
        let midY = image.height / 2
        let dividerPixel = pixelColor(in: image, x: verticalDividerX, y: midY)

        XCTAssertGreaterThan(
            dividerPixel.a, UInt8(200),
            "vertical divider pixel must be opaque"
        )
        // gridColor is opaque black; backgroundColor is opaque white -- a divider pixel must
        // read as dark, not as the white background (checked per-channel to avoid summing
        // three UInt8s, which can overflow for lighter grid colors).
        XCTAssertLessThan(dividerPixel.r, UInt8(50), "vertical divider pixel must be dark (grid color), not background")
        XCTAssertLessThan(dividerPixel.g, UInt8(50), "vertical divider pixel must be dark (grid color), not background")
        XCTAssertLessThan(dividerPixel.b, UInt8(50), "vertical divider pixel must be dark (grid color), not background")
    }

    func testGridLinesAreVisible_horizontalDivider() {
        let cells: [[TextDescriptor]] = [
            [makeCell("A")],
            [makeCell("B")]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]
        let gridLineWidth: CGFloat = 1

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: gridLineWidth,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster for non-degenerate content")
        }

        // Horizontal divider between rows: y = layout.rows[0].frame.height + gridLineWidth/2
        let row0Height = layout.rows[0].frame.height
        let horizontalDividerY = Int((row0Height + gridLineWidth / 2).rounded())
        let midX = image.width / 2
        let dividerPixel = pixelColor(in: image, x: midX, y: horizontalDividerY)

        XCTAssertGreaterThan(
            dividerPixel.a, UInt8(200),
            "horizontal divider pixel must be opaque"
        )
    }

    // MARK: - Test 2: Cell text placed correctly within its own region

    func testCellTextPlacedCorrectly_eachRowStaysInOwnBand() {
        // Distinct hues per row (not just distinct content) so a bleed/offset-swap bug --
        // row 1's text landing in row 0's band or vice versa -- is actually observable: a
        // presence-only check ("row N has *some* ink") can't tell whose ink it is.
        let red = VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        let cells: [[TextDescriptor]] = [
            [makeCell("A", color: red)],
            [makeCell("B", color: blue)]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]
        let gridLineWidth: CGFloat = 1

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: gridLineWidth,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        // Row 0 starts at y = gridLineWidth, ends at y = gridLineWidth + row0.height
        let row0Start = Int(gridLineWidth)
        let row0End = Int(gridLineWidth + layout.rows[0].frame.height)
        let row0Range = row0Start..<row0End

        // Row 1 starts after the divider
        let row1Start = row0End + Int(gridLineWidth)
        let row1End = row1Start + Int(layout.rows[1].frame.height)
        let row1Range = row1Start..<row1End

        // Both the background (opaque white) and the gridlines (opaque black) are fully opaque,
        // same as solid glyph ink -- `dominantInkColor`'s "highest alpha wins" can't tell them
        // apart from real text ink here (unlike CodeBlockRasterizerTests' transparent-background
        // canvas, where ink is the only opaque thing). Search for the most *saturated* pixel
        // instead: white/black are achromatic (r == g == b), while the red/blue text isn't --
        // this finds the real ink regardless of alpha and is naturally immune to the achromatic
        // gridline columns too, so no xRange exclusion is needed.
        let row0Ink = mostSaturatedPixel(in: image, xRange: 0..<image.width, yRange: row0Range)
        let row1Ink = mostSaturatedPixel(in: image, xRange: 0..<image.width, yRange: row1Range)

        XCTAssertGreaterThan(row0Ink.a, 0, "row 0 must have ink")
        XCTAssertGreaterThan(row1Ink.a, 0, "row 1 must have ink")
        XCTAssertGreaterThan(row0Ink.r, row0Ink.b, "row 0's own band must show its red text, not row 1's blue")
        XCTAssertGreaterThan(row1Ink.b, row1Ink.r, "row 1's own band must show its blue text, not row 0's red")
    }

    // MARK: - Test 3: Header row (bold font) rasterizes

    func testHeaderRowBoldFontRasterizes() {
        let headerCell = makeCell(
            "Header",
            font: VFontDescriptor(size: 16, weight: VFontDescriptor.boldWeight)
        )
        let bodyCell = makeCell(
            "Body",
            font: VFontDescriptor(size: 16, weight: VFontDescriptor.regularWeight)
        )

        let cells: [[TextDescriptor]] = [
            [headerCell],
            [bodyCell]
        ]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: 1,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        let gridLineWidth = 1
        let row0Start = Int(CGFloat(gridLineWidth))
        let row0End = Int(CGFloat(gridLineWidth) + layout.rows[0].frame.height)
        let headerRange = row0Start..<row0End

        // Header text is black (achromatic) on an opaque white background, so `mostSaturatedPixel`
        // can't distinguish them (both r == g == b). Use the darkest pixel instead, restricted to
        // the content columns so the equally-dark outer gridline border can't be picked up as a
        // false "header ink" signal.
        let contentXRange = Int(gridLineWidth)..<(image.width - Int(gridLineWidth))
        let headerInk = darkestPixel(in: image, xRange: contentXRange, yRange: headerRange)
        XCTAssertLessThan(
            Int(headerInk.r) + Int(headerInk.g) + Int(headerInk.b), 700,
            "header row must show dark glyph ink, not just the white background"
        )
    }

    // MARK: - Test 4: Corners rounded via CGContext clip

    func testCornersRoundedViaContextClip_cornerPixelTransparent() {
        let cells: [[TextDescriptor]] = [[makeCell("Text")]]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            cornerRadius: 12,
            gridLineWidth: 1,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        let cornerPixel = pixelColor(in: image, x: 0, y: 0)
        XCTAssertEqual(
            cornerPixel.a, 0,
            "corner pixel must be fully transparent (clipped out)"
        )
    }

    func testCornersRoundedViaContextClip_zeroRadiusCornerOpaque() {
        let cells: [[TextDescriptor]] = [[makeCell("Text")]]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            cornerRadius: 0,
            gridLineWidth: 1,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        let cornerPixel = pixelColor(in: image, x: 0, y: 0)
        XCTAssertGreaterThan(
            cornerPixel.a, UInt8(200),
            "zero corner radius must not clip any pixel"
        )
    }

    // MARK: - Test 5: Output is BGRA8888 premultiplied

    func testOutputIsBGRA8888Premultiplied() {
        let cells: [[TextDescriptor]] = [[makeCell("Text")]]
        let columnWidths: [CGFloat] = [100]
        let alignments: [TableColumnAlignment] = [.left]

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        XCTAssertTrue(isBGRA8888(image), "output must be BGRA8888 premultiplied")
    }

    // MARK: - Test 6: Reported dimensions equal Σ column widths/row heights + gridlines

    func testReportedDimensionsIncludeGridlines() {
        let cells: [[TextDescriptor]] = [
            [makeCell("A"), makeCell("B")],
            [makeCell("C"), makeCell("D")]
        ]
        let columnWidths: [CGFloat] = [80, 120]
        let alignments: [TableColumnAlignment] = [.left, .left]
        let gridLineWidth: CGFloat = 1

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )

        let (image, size) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: gridLineWidth,
            scale: 1
        )
        guard let image else {
            return XCTFail("expected a non-nil raster")
        }

        let columnCount = columnWidths.count
        let rowCount = layout.rows.count
        let totalRowHeights = layout.rows.reduce(0) { $0 + $1.frame.height }
        let totalColumnWidths = columnWidths.reduce(0, +)

        let expectedWidth = totalColumnWidths + CGFloat(columnCount + 1) * gridLineWidth
        let expectedHeight = totalRowHeights + CGFloat(rowCount + 1) * gridLineWidth

        // `rasterizeTable` snaps its canvas to the pixel grid at `scale` (so the renderer's
        // backing store and `normaliseAndRound`'s pixel-size check always agree -- see its own
        // doc comment); at scale 1 that can move the reported size by up to 0.5pt from the raw
        // Σ+gridlines sum computed here from real (fractional) text measurement.
        XCTAssertEqual(size.width, expectedWidth, accuracy: 0.5,
                       "reported width must equal Σ columnWidths + (columnCount+1)*gridLineWidth, within pixel snapping")
        XCTAssertEqual(size.height, expectedHeight, accuracy: 0.5,
                       "reported height must equal Σ rowHeights + (rowCount+1)*gridLineWidth, within pixel snapping")
        XCTAssertEqual(size.width, CGFloat(image.width), accuracy: 0.01,
                       "reported width must match actual bitmap width")
        XCTAssertEqual(size.height, CGFloat(image.height), accuracy: 0.01,
                       "reported height must match actual bitmap height")
    }

    // MARK: - Test 7: No glyph clipping on bold header's trailing glyph

    func testBoldHeaderTrailingGlyphNotClipped() {
        let wideHeaderContent = String(repeating: "W", count: 20)
        let headerCell = makeCell(
            wideHeaderContent,
            font: VFontDescriptor(size: 16, weight: VFontDescriptor.boldWeight)
        )

        let cells: [[TextDescriptor]] = [[headerCell]]
        let columnWidths: [CGFloat] = [200]
        let alignments: [TableColumnAlignment] = [.left]
        let padding = TableCellPadding.default
        let gridLineWidth: CGFloat = 1
        let scale: CGFloat = 1

        let layout = layoutTableCells(
            cells: cells,
            columnWidths: columnWidths,
            alignments: alignments,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) },
            padding: padding
        )

        // Build a reference raster of the header cell alone
        let cell = layout.rows[0].cells[0]
        let contentWidth = max(0, columnWidths[0] - 2 * padding.horizontal)
        guard let referenceImage = rasterizeText(
            cell.descriptor,
            layoutWidth: contentWidth,
            outputSize: cell.textFrame.size,
            scale: scale,
            inkGuard: codeInkRightGuard
        ) else {
            return XCTFail("expected a reference raster of the header cell")
        }

        let (tableImage, _) = rasterizeTable(
            layout: layout,
            gridColor: gridColor,
            backgroundColor: backgroundColor,
            gridLineWidth: gridLineWidth,
            padding: padding,
            scale: scale
        )
        guard let tableImage else {
            return XCTFail("expected a non-nil table raster")
        }

        // Column 0 starts at x = gridLineWidth in the final image
        let columnOffsetPixels = Int(gridLineWidth * scale)
        let referenceRight = rightmostInkPixel(in: referenceImage)
        let tableRight = rightmostInkPixel(in: tableImage) - columnOffsetPixels

        XCTAssertGreaterThanOrEqual(
            tableRight, referenceRight - 1,
            "table's trailing glyph ink must reach at least as far right as the reference (within 1 pixel rounding)"
        )
    }

    // MARK: - Test 8: Degenerate empty layout returns nil/zero

    func testDegenerateEmptyLayoutReturnsNilAndZero() {
        let emptyLayout = ResolvedTableLayout(rows: [], columnWidths: [], size: .zero)

        let (image, size) = rasterizeTable(
            layout: emptyLayout,
            gridColor: gridColor,
            backgroundColor: backgroundColor
        )

        XCTAssertNil(image, "empty layout must return nil image")
        XCTAssertEqual(size.width, 0, accuracy: 0.01)
        XCTAssertEqual(size.height, 0, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func makeCell(
        _ content: String,
        font: VFontDescriptor = VFontDescriptor(size: 16, weight: VFontDescriptor.regularWeight),
        color: VColorDescriptor = VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: font,
            color: color,
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

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

    /// The pixel with the largest RGB spread (max channel - min channel) in the given ranges --
    /// distinguishes chromatic ink (e.g. red/blue text) from an achromatic fill (white background,
    /// black gridlines both have r == g == b), regardless of alpha. Unlike `dominantInkColor`
    /// (max-alpha search), this works even when the background is fully opaque, not just
    /// transparent.
    private func mostSaturatedPixel(
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

        var best: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255)
        var bestSpread = -1
        for row in yRange.clamped(to: 0..<h) {
            let flippedY = h - 1 - row
            for col in xRange.clamped(to: 0..<w) {
                let offset = (flippedY * w + col) * 4
                let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                let spread = Int(max(r, g, b)) - Int(min(r, g, b))
                if spread > bestSpread {
                    bestSpread = spread
                    best = (r, g, b, bytes[offset + 3])
                }
            }
        }
        return best
    }

    /// The pixel with the lowest total brightness (r+g+b, as Int to avoid UInt8 overflow) in the
    /// given ranges -- finds black-on-white ink where `mostSaturatedPixel` can't (both are
    /// achromatic).
    private func darkestPixel(
        in image: CGImage, xRange: Range<Int>, yRange: Range<Int>
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return (255, 255, 255, 255) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (255, 255, 255, 255) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var best: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255)
        var bestBrightness = Int.max
        for row in yRange.clamped(to: 0..<h) {
            let flippedY = h - 1 - row
            for col in xRange.clamped(to: 0..<w) {
                let offset = (flippedY * w + col) * 4
                let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                let brightness = Int(r) + Int(g) + Int(b)
                if brightness < bestBrightness {
                    bestBrightness = brightness
                    best = (r, g, b, bytes[offset + 3])
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
