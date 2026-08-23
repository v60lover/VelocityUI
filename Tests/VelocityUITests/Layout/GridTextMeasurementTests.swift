// GridTextMeasurementTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Regression guard for the grid's measure-at-colWidth contract (`GRID_LAYOUT_DESIGN.md` §D5,
/// `SECTIONED_GRID_DESIGN.md` §D6): a grid cell must be measured at the column width, not scaled
/// down from a full-width measurement, because text re-wraps at the narrower width instead of
/// shrinking linearly. Exercises the real `measureNode` + `TextMeasurementPool` pipeline —
/// `GridLayoutProviderTests`/`GridLayoutTests` (VelocityUI-xhpu.3) only check that
/// `measureWidth(availableWidth:)` returns the right NUMBER; this checks that measuring at that
/// number actually produces a taller (re-wrapped), not merely scaled, result.
final class GridTextMeasurementTests: XCTestCase {

    private func textDesc(_ content: String, hash: Int = 1) -> TextDescriptor {
        TextDescriptor(content: content, font: VFontDescriptor(size: 16, weight: 0),
                       color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                       lineLimit: nil, lineBreakMode: 0,
                       layoutHash: hash, appearanceHash: hash)
    }

    /// Long enough to wrap across several lines at a ~100pt column width, and across fewer
    /// (but still >1) lines at 320pt full width — so both measurements are real multi-line
    /// TextKit layouts, not a single-line degenerate case either width would trivially satisfy.
    private let paragraph = """
    VelocityUI renders feeds with a CALayer-backed engine. Every cell in a grid column is \
    measured at the column's own width, not the full container width, because text wraps \
    narrower there — height is not a linear function of column count.
    """

    func testTextCellMeasuredAtColumnWidth_isTallerThanAtFullWidth() async throws {
        let fullWidth: CGFloat = 320
        let columns = 3
        let spacing: CGFloat = 8
        let colWidth = GridLayoutProvider(columns: columns, spacing: spacing).measureWidth(availableWidth: fullWidth)
        XCTAssertLessThan(colWidth, fullWidth, "precondition: colWidth must actually be narrower than full width")

        let table = NodeTable(
            itemID: "text-wrap",
            nodes: [.text(textDesc(paragraph))],
            parentIndices: [-1],
            layoutHash: 1, appearanceHash: 1
        )

        let pool = TextMeasurementPool(capacity: 1)
        let fullWidthLayout = await measureNode(table, nodeIndex: 0, width: fullWidth, textPool: pool)
        let colWidthLayout  = await measureNode(table, nodeIndex: 0, width: colWidth,  textPool: pool)

        XCTAssertGreaterThan(colWidthLayout.totalFrame.height, fullWidthLayout.totalFrame.height,
            "text re-wrapped at the narrower column width must measure TALLER than at full width — "
            + "a regression that scales height instead of re-measuring would fail this")

        // Direct guard against the literal "divide by columns" bug: a naive
        // `fullWidthHeight / columns` would produce a SHORTER height than the real re-wrapped
        // text, since wrapping adds lines rather than shrinking line height.
        let naiveDividedHeight = fullWidthLayout.totalFrame.height / CGFloat(columns)
        XCTAssertNotEqual(colWidthLayout.totalFrame.height, naiveDividedHeight, accuracy: 0.5,
            "colWidth measurement must not coincidentally equal fullWidthHeight/columns — "
            + "that would indicate a divide-instead-of-remeasure regression")
        XCTAssertGreaterThan(colWidthLayout.totalFrame.height, naiveDividedHeight,
            "real re-wrapped height at colWidth must exceed the naive divided-by-columns height")
    }
}
#endif
