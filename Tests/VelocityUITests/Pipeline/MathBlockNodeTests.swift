// MathBlockNodeTests.swift

#if canImport(UIKit)
import XCTest
import SwaTex
import SwaTexRender
@testable import VelocityUI

/// Covers VelocityUI-gojy.3's acceptance criteria end to end: a `$$..$$` / `\[..\]` formula
/// renders centered as its own block; a wide formula scrolls horizontally via Variant B; a
/// malformed formula degrades to literal TeX text; no `CATextLayer`.
///
/// | # | Invariant being verified | Assertion |
/// |---|---|---|
/// | 1 | `MathBlockNode` flattens to a single `.mathBlock` leaf, no nested container | `table.nodes.count == 1`; `case .mathBlock` |
/// | 2 | Valid TeX parses into a formula layout, not the literal fallback | `layoutMathBlock` returns `.formula` |
/// | 3 | Malformed TeX degrades to literal text, never crashes | `layoutMathBlock` returns `.literal` carrying the raw source |
/// | 4 | Formula raster is BGRA8888 premultiplied | `isBGRA8888(image)` |
/// | 5 | A formula narrower than the block is centered (padding both sides) | leftmost/rightmost ink columns roughly symmetric |
/// | 6 | A formula wider than the block is not clamped -- canvas == formula's natural width, flush left | `size.width` ≈ `metrics.width`, leftmost ink ≈ 0 |
/// | 7 | `LayoutEngine`'s `.mathBlock` case pins the outer frame to the proposed width | `layout.totalFrame.width == width` even for a wide formula |
/// | 8 | The real (possibly wider) content size travels via a `.mathBody` child | child's width > `width` for a wide formula |
/// | 9 | `extractFragments` emits one `.mathBlock` Fragment with that natural content size, frame pinned to width | fragment content + frame assertions |
/// | 10 | Variant B: `RenderCell.codeBodyIdentity(at:)` is non-nil only when mounted content overflows the frame | mount narrow vs. wide, assert nil vs. non-nil |
/// | 11 | No `CATextLayer` anywhere in the mounted math-block layers | `!(layer is CATextLayer)` |
/// | 12 | Sealed math block caches once (StreamingMarkdownController) | NOT a new test -- the cache is `NodeKind`-agnostic, already covered by `testStreamingMarkdownController_NewlySealedBlock_StylesOnceThenCaches` |
final class MathBlockNodeTests: XCTestCase {
    private let font = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight)

    // MARK: - 1. Flatten shape

    @MainActor
    func testFlatten_MathBlockDescriptorIsLossless_SingleLeaf() {
        let node = MathBlockNode(rawTeX: "x^2 + y^2 = z^2", font: font)
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.nodes.count, 1, "a math block must remain a single NodeTable node")
        guard case .mathBlock(let descriptor) = table.nodes.first else {
            return XCTFail("a math block must emit a .mathBlock(descriptor) node kind")
        }
        XCTAssertEqual(descriptor.rawTeX, "x^2 + y^2 = z^2")
    }

    // MARK: - 2/3. layoutMathBlock: formula vs. literal fallback

    func testLayoutMathBlock_ValidTeX_ProducesFormula() {
        let layout = layoutMathBlock(
            rawTeX: "x^2", font: font, color: .primary, width: 300, cache: nil,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        guard case .formula = layout else {
            return XCTFail("valid TeX must produce a .formula layout, not literal fallback")
        }
    }

    func testLayoutMathBlock_MalformedTeX_DegradesToLiteral() {
        // `\frac` missing its second argument -- a genuine SwaTex ParseError (see
        // SwaTexTests/FormulaCacheTests.swift's own fixture for the same source).
        let malformed = #"\frac{1}"#
        let layout = layoutMathBlock(
            rawTeX: malformed, font: font, color: .primary, width: 300, cache: nil,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        guard case .literal(let descriptor, let size) = layout else {
            return XCTFail("malformed TeX must degrade to a .literal fallback, never crash")
        }
        XCTAssertEqual(descriptor.content, malformed, "the literal fallback must show the raw TeX verbatim")
        XCTAssertGreaterThan(size.height, 0, "literal fallback must have a real measured size")
    }

    // MARK: - 4/5/6. rasterizeMathBlock geometry + format

    func testRasterizeMathBlock_Formula_IsBGRA8888() throws {
        let layout = layoutMathBlock(
            rawTeX: "x^2", font: font, color: .primary, width: 300, cache: nil,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        let raster = rasterizeMathBlock(layout, blockWidth: 300, scale: 2, fontProvider: KaTeXFontProvider())
        guard let image = raster.image else { return XCTFail("expected a non-nil raster for valid TeX") }
        XCTAssertTrue(isBGRA8888(image), "math raster must be BGRA8888 premultiplied, matching the decode-time invariant every other rasterizer in this codebase follows")
    }

    func testRasterizeMathBlock_NarrowerThanBlock_IsCenteredWithPaddingBothSides() throws {
        let rawTeX = "x"
        let blockWidth: CGFloat = 400
        let layout = layoutMathBlock(
            rawTeX: rawTeX, font: font, color: .primary, width: blockWidth, cache: nil,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        guard case .formula(_, _, let metrics) = layout else { return XCTFail("expected a formula layout") }
        XCTAssertLessThan(metrics.width, blockWidth, "precondition: the formula must be narrower than the block for this test to be meaningful")

        let raster = rasterizeMathBlock(layout, blockWidth: blockWidth, scale: 1, fontProvider: KaTeXFontProvider())
        guard let image = raster.image else { return XCTFail("expected a non-nil raster") }
        XCTAssertEqual(raster.size.width, blockWidth, accuracy: 0.5, "canvas must equal the block width when the formula fits, so it can be centered within it")

        guard let leftInk = firstInkColumn(in: image), let rightInk = lastInkColumn(in: image) else {
            return XCTFail("expected visible ink in the raster")
        }
        let leftMargin = leftInk
        let rightMargin = image.width - 1 - rightInk
        XCTAssertEqual(
            leftMargin, rightMargin, accuracy: max(2, Int(0.05 * Double(image.width))),
            "ink must be roughly centered -- left and right margins should match"
        )
    }

    func testRasterizeMathBlock_WiderThanBlock_IsNotClampedAndStartsFlushLeft() throws {
        let rawTeX = #"x^{2} + y^{2} + z^{2} + a^{2} + b^{2} + c^{2} + d^{2} + e^{2} + f^{2} + g^{2}"#
        let blockWidth: CGFloat = 50
        let layout = layoutMathBlock(
            rawTeX: rawTeX, font: font, color: .primary, width: blockWidth, cache: nil,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        guard case .formula(_, _, let metrics) = layout else { return XCTFail("expected a formula layout") }
        XCTAssertGreaterThan(metrics.width, blockWidth, "precondition: the formula must be wider than the block for this test to be meaningful")

        let raster = rasterizeMathBlock(layout, blockWidth: blockWidth, scale: 1, fontProvider: KaTeXFontProvider())
        guard let image = raster.image else { return XCTFail("expected a non-nil raster") }
        XCTAssertEqual(raster.size.width, metrics.width, accuracy: 0.5, "canvas must equal the formula's own natural width, never clamped to the block width")

        guard let leftInk = firstInkColumn(in: image) else { return XCTFail("expected visible ink") }
        // Ink starts at SwaTex's own intrinsic `mathBlockPadding` (baked into every glyph
        // position by `DisplayListRenderer.draw`, on every side, regardless of centering), not
        // at column 0 -- dx == 0 here means "no EXTRA offset on top of that", which is what
        // distinguishes this from the centered (narrower-than-block) case.
        XCTAssertEqual(
            CGFloat(leftInk), mathBlockPadding, accuracy: 3,
            "an overflowing formula has nothing to center against -- it must start at SwaTex's own padding, dx == 0, not pushed further right"
        )
    }

    // MARK: - 7/8. LayoutEngine's .mathBlock measure case

    private func mathTable(rawTeX: String, itemID: String = "t1") -> NodeTable {
        let descriptor = MathBlockDescriptor(
            rawTeX: rawTeX, font: font, color: .primary, blockID: nil, lifecycle: .positional,
            layoutHash: 1, appearanceHash: 1
        )
        return NodeTable(
            itemID: itemID, nodes: [.mathBlock(descriptor)], parentIndices: [-1],
            layoutHash: 10, appearanceHash: 10
        )
    }

    func testMeasureNode_WideFormula_PinsOuterFrameToProposedWidth() async throws {
        let rawTeX = #"x^{2} + y^{2} + z^{2} + a^{2} + b^{2} + c^{2} + d^{2} + e^{2} + f^{2} + g^{2}"#
        let table = mathTable(rawTeX: rawTeX)
        let pool = TextMeasurementPool(capacity: 1)
        let narrowWidth: CGFloat = 50

        let layout = await measureNode(table, nodeIndex: 0, width: narrowWidth, textPool: pool)

        XCTAssertEqual(layout.totalFrame.width, narrowWidth, "the card frame must never expand past the proposed container width, even for a wide formula")
    }

    func testMeasureNode_WideFormula_MathBodyChildCarriesRealWiderWidth() async throws {
        let rawTeX = #"x^{2} + y^{2} + z^{2} + a^{2} + b^{2} + c^{2} + d^{2} + e^{2} + f^{2} + g^{2}"#
        let table = mathTable(rawTeX: rawTeX)
        let pool = TextMeasurementPool(capacity: 1)
        let narrowWidth: CGFloat = 50

        let layout = await measureNode(table, nodeIndex: 0, width: narrowWidth, textPool: pool)
        let body = layout.children.first { $0.renderPart == .mathBody }
        XCTAssertNotNil(body, "measureNode must attach a .mathBody child carrying the natural content size")
        XCTAssertGreaterThan(
            body?.totalFrame.width ?? 0, narrowWidth,
            "the .mathBody child must carry the formula's real (wider) natural width, mirroring .tableBody"
        )
    }

    // MARK: - 9. extractFragments

    func testExtractFragments_MathBlock_ProducesOneMathBlockFragment() async throws {
        let rawTeX = "x^2"
        let table = mathTable(rawTeX: rawTeX)
        let pool = TextMeasurementPool(capacity: 1)
        let width: CGFloat = 300

        let layout = await measureNode(table, nodeIndex: 0, width: width, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 1)
        guard case .mathBlock(let descriptor) = fragments[0].content else {
            return XCTFail("expected a single .mathBlock fragment")
        }
        XCTAssertEqual(fragments[0].frame.width, width, "the fragment's own frame stays pinned to the card width")
        XCTAssertGreaterThan(descriptor.naturalContentSize.width, 0)
    }

    // MARK: - 10/11. RenderCell mount: Variant B threshold + no CATextLayer

    @MainActor
    private func makeCell(size: CGSize = CGSize(width: 320, height: 400)) -> RenderCell {
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        return cell
    }

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        return context.makeImage()!
    }

    @MainActor
    private func mountMathFragment(
        on cell: RenderCell, id: Int, itemID: AnyHashable, frameWidth: CGFloat, naturalContentWidth: CGFloat
    ) -> Fragment {
        cell.prepareForReuse(for: itemID)
        let fragment = Fragment(
            id: id,
            content: .mathBlock(MathBlockRasterDescriptor(
                naturalContentSize: CGSize(width: naturalContentWidth, height: 60),
                layoutHash: 1, appearanceHash: 1
            )),
            frame: CGRect(x: 0, y: 0, width: frameWidth, height: 60)
        )
        let image = makeCGImage(width: Int(naturalContentWidth), height: 60)
        _ = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame,
            synchronousContent: [fragment.id: image]
        )
        return fragment
    }

    @MainActor
    func testRenderCell_MathBlock_OverflowingContent_IsScrollable() {
        let cell = makeCell()
        let fragment = mountMathFragment(on: cell, id: 1, itemID: "item-1", frameWidth: 300, naturalContentWidth: 900)

        let identity = cell.codeBodyIdentity(at: CGPoint(x: fragment.frame.midX, y: fragment.frame.midY))
        XCTAssertNotNil(identity, "content wider than the fragment's frame must be scrollable via Variant B")
    }

    @MainActor
    func testRenderCell_MathBlock_FittingContent_IsNotScrollable() {
        let cell = makeCell()
        let fragment = mountMathFragment(on: cell, id: 1, itemID: "item-1", frameWidth: 300, naturalContentWidth: 200)

        let identity = cell.codeBodyIdentity(at: CGPoint(x: fragment.frame.midX, y: fragment.frame.midY))
        XCTAssertNil(identity, "content that already fits the frame must not report as scrollable")
    }

    @MainActor
    func testRenderCell_MathBlock_MountedLayers_AreNeverCATextLayer() {
        let cell = makeCell()
        let fragment = mountMathFragment(on: cell, id: 1, itemID: "item-1", frameWidth: 300, naturalContentWidth: 900)

        guard let identity = cell.layerIdentityByFragmentID[fragment.id] else {
            return XCTFail("expected a layer identity after mounting a math fragment")
        }
        // `codeTailSublayers` (the actual content layer holding the raster) is `private` to
        // RenderCell -- not reachable even via @testable. `codeBodyClipLayer`/`sublayers` are the
        // module-visible layers this mount path creates; the content layer's own invariant is
        // already enforced at mount time by `applyLayout`'s embedded `assertLayerInvariants` call
        // on every DEBUG build (would have trapped before this test could observe a violation).
        XCTAssertFalse(cell.codeBodyClipLayer[identity] is CATextLayer)
        XCTAssertFalse(cell.sublayers[identity] is CATextLayer)
    }

    // MARK: - Pixel helpers (mirrors TableRasterizerTests.swift's pixelColor helper)

    private func firstInkColumn(in image: CGImage) -> Int? {
        inkColumns(in: image).first
    }

    private func lastInkColumn(in image: CGImage) -> Int? {
        inkColumns(in: image).last
    }

    /// Columns (x-coordinates) containing at least one non-transparent pixel, scanning the
    /// vertical midline band -- cheap enough for these small formula rasters and avoids a full
    /// O(w*h) scan while still being robust to where exactly the glyph ink sits vertically.
    private func inkColumns(in image: CGImage) -> [Int] {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var columns: [Int] = []
        for x in 0..<w {
            var hasInk = false
            for y in 0..<h {
                let alpha = bytes[(y * w + x) * 4 + 3]
                if alpha > 10 { hasInk = true; break }
            }
            if hasInk { columns.append(x) }
        }
        return columns
    }
}
#endif
